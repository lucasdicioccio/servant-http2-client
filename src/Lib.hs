{-# LANGUAGE DataKinds      #-}
{-# LANGUAGE TypeOperators  #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE InstanceSigs   #-}
{-# LANGUAGE GeneralizedNewtypeDeriving   #-}
{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE MultiParamTypeClasses   #-}
module Lib
    ( someFunc
    ) where

import           Data.IORef
import           Data.Foldable
import           Control.Exception (throwIO)
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Except
import           Control.Monad.Error.Class   (MonadError (..))
import           Control.Monad.Reader
import           Data.Aeson (eitherDecode)
import           Data.Binary.Builder (toLazyByteString)
import           Data.ByteString.Builder
import           Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as ByteString
import           Data.ByteString.Lazy (fromStrict, toStrict, toChunks)
import qualified Data.ByteString.Lazy as LByteString
import           Data.Default.Class (def)
import           Data.Foldable (toList)
import           Data.Sequence (fromList)
import           Data.Text.Encoding as Encoding
import           GHC.Generics
import           Servant.API
import           Servant.Client.Core
import           Servant.Client.Core.Internal.RunClient
import           Network.HPACK
import           Network.HTTP.Media.RenderHeader
import           Network.HTTP2
import           Network.HTTP2.Client
import           Network.HTTP2.Client.Helpers
import           Network.HTTP.Types.Status
import           Network.HTTP.Types.Version
import qualified Network.TLS as TLS
import qualified Network.TLS.Extra.Cipher as TLS
import qualified Data.CaseInsensitive as CI
import           Text.Read

import           Data.Aeson (FromJSON,ToJSON)
import           Data.Text (Text)
import           Data.Proxy

newtype H2ClientM a = H2ClientM
  { unH2ClientM :: ReaderT H2ClientEnv (ExceptT ServantError IO) a }
  deriving ( Functor, Applicative, Monad, MonadIO, Generic
           , MonadReader H2ClientEnv, MonadError ServantError, MonadThrow
           , MonadCatch)

runH2ClientM :: H2ClientM a -> H2ClientEnv -> IO (Either ServantError a)
runH2ClientM cm env = runExceptT $ flip runReaderT env $ unH2ClientM cm

instance RunClient H2ClientM where
  runRequest :: Request -> H2ClientM Response
  runRequest = performRequest
  streamingRequest :: Request -> H2ClientM StreamingResponse
  streamingRequest = performStreamingRequest
  throwServantError :: ServantError -> H2ClientM a
  throwServantError = throwError

data H2ClientEnv = H2ClientEnv ByteString Http2Client

type ByteSegments = (IO ByteString -> IO ()) -> IO ()

sendSegments http2client stream ocfc osfc segments =
    segments go
  where
    go getChunk = do
        dat <- getChunk
        upload dat id http2client ocfc stream osfc

onlySegment :: ByteString -> ByteSegments
onlySegment bs handle = handle (pure bs)

multiSegments :: [ByteString] -> ByteSegments
multiSegments bss handle =
    traverse_ (handle . pure) (filter (not . ByteString.null) bss)

makeRequest
  :: ByteString
  -> Request
  -> IO (ByteSegments, HeaderList)
makeRequest authority req = do
    let go ct obj = case obj of
            (RequestBodyBS bs)  -> pure $
                (onlySegment bs,
                    [ ("Content-Type", renderHeader ct)
                    , ("Content-Length", ByteString.pack $ show $ ByteString.length bs)
                    ])
            (RequestBodyLBS lbs) -> pure $
                (multiSegments $ toChunks lbs,
                    [ ("Content-Type", renderHeader ct)
                    ])
            (RequestBodyBuilder n builder) ->
                let lbs = toLazyByteString builder in pure $
                (multiSegments $ toChunks lbs,
                    [ ("Content-Type", renderHeader ct)
                    , ("Content-Length", ByteString.pack $ show n)
                    ])
            (RequestBodyStream n act) -> pure $
                (act,
                    [ ("Content-Type", renderHeader ct)
                    , ("Content-Length", ByteString.pack $ show n)
                    ])
            (RequestBodyStreamChunked act) -> pure $
                (act,
                    [ ("Content-Type", renderHeader ct)
                    , ("Transfer-Encoding", "chunked")
                    ])
            (RequestBodyIO again) ->
                again >>= go ct

    (bodyIO,bodyheaders) <- case requestBody req of
                                Nothing       -> pure (onlySegment "", [])
                                (Just (r,ct)) -> go ct r
    let headersPairs = baseHeaders <> reqHeaders <> bodyheaders
    pure (bodyIO, headersPairs)
  where
    baseHeaders =
        [ (":method", requestMethod req)
        , (":scheme", "https")
        , (":path", toStrict $ toLazyByteString $ requestPath req)
        , (":authority", authority)
        , ("Accept", ByteString.intercalate "," $ toList $ fmap renderHeader $ requestAccept req)
        , ("User-Agent", "servant-http2-client/dev")
        ]
    reqHeaders = [(CI.original h, hv) | (h,hv) <- toList (requestHeaders req)]

performRequest :: Request -> H2ClientM Response
performRequest req = do
    H2ClientEnv authority http2client <- ask
    let icfc = _incomingFlowControl http2client
    let ocfc = _outgoingFlowControl http2client
    let headersFlags = id
    let resetPushPromises _ pps _ _ _ = _rst pps RefusedStream

    (bodyIO, headersPairs) <- liftIO $ makeRequest authority req
    http2rsp <- liftIO $ withHttp2Stream http2client $ \stream ->
        let initStream =
                headers stream headersPairs headersFlags
            handler isfc osfc = do
                sendSegments http2client stream ocfc osfc bodyIO
                sendData http2client stream setEndStream ""
                streamResult <- waitStream stream icfc resetPushPromises
                pure $ fromStreamResult streamResult
        in (StreamDefinition initStream handler)
    let response = case http2rsp of
            Right (Right (hdrs,body,_))
                | let Just status = readMaybe . ByteString.unpack =<< lookup ":status" hdrs ->
                        Response (Status status "") (fromList [ (CI.mk h, hv) | (h,hv) <- hdrs ]) http20 (fromStrict body)
    pure response

performStreamingRequest :: Request -> H2ClientM StreamingResponse
performStreamingRequest req = do
    H2ClientEnv authority http2client <- ask
    let icfc = _incomingFlowControl http2client
    let ocfc = _outgoingFlowControl http2client
    let headersFlags = id
    let resetPushPromises _ pps _ _ _ = _rst pps RefusedStream

    (bodyIO, headersPairs) <- liftIO $ makeRequest authority req
    ret <- liftIO $ withHttp2Stream http2client $ \stream ->
        let initStream =
                headers stream headersPairs headersFlags
            handler isfc osfc = do
                isFinished <- newIORef False
                let nextChunk = do
                        done <- readIORef isFinished
                        if done
                        then pure ""
                        else do
                            ev <- _waitEvent stream
                            case ev of
                                (StreamDataEvent frameHeader dat) -> do
                                    _addCredit isfc (ByteString.length dat)
                                    _ <- _consumeCredit isfc (ByteString.length dat)
                                    _ <- _updateWindow isfc
                                    _addCredit icfc (ByteString.length dat)
                                    _ <- _updateWindow icfc
                                    when (testEndStream $ flags frameHeader) $
                                        writeIORef isFinished True
                                    pure dat
                sendSegments http2client stream ocfc osfc bodyIO
                sendData http2client stream setEndStream ""
                pure $ StreamingResponse (\handleGenResponse -> do
                    ev <- _waitEvent stream
                    case ev of
                        (StreamHeadersEvent frameHeader hdrs) -> do
                             when (testEndStream $ flags frameHeader) $
                                 writeIORef isFinished True
                             let Just status = readMaybe . ByteString.unpack =<< lookup ":status" hdrs
                             handleGenResponse $ Response (Status status "") (fromList [ (CI.mk h, hv) | (h,hv) <- hdrs ]) http20 nextChunk)
        in (StreamDefinition initStream handler)
    case ret of
        Right ret -> pure ret

h2client :: HasClient H2ClientM api => Proxy api -> Client H2ClientM api
h2client api = api `clientIn` (Proxy :: Proxy H2ClientM)

data RawText
instance Accept RawText where
  contentType _ = "text/plain"
instance MimeRender RawText Text where
  mimeRender _ = fromStrict . Encoding.encodeUtf8
instance MimeUnrender RawText Text where
  mimeUnrender _ = pure . Encoding.decodeUtf8 . toStrict
instance MimeUnrender OctetStream Text where
  mimeUnrender _ = pure . Encoding.decodeUtf8 . toStrict

--- usage ---
type Http2Golang =
       "reqinfo" :> Get '[RawText] Text
  :<|> "goroutines" :> StreamGet NewlineFraming RawText (ResultStream Text)
  :<|> "ECHO" :> ReqBody '[RawText] Text :> Put '[OctetStream] Text

myApi :: Proxy Http2Golang
myApi = Proxy

getExample :: H2ClientM Text
getGoroutines :: H2ClientM (ResultStream Text)
capitalize :: Text -> H2ClientM Text
getExample :<|> getGoroutines :<|> capitalize = h2client myApi

someFunc :: IO ()
someFunc = do
    frameConn <- newHttp2FrameConnection "http2.golang.org" 443 (Just tlsParams)
    client <- newHttp2Client frameConn 8192 8192 [] defaultGoAwayHandler ignoreFallbackHandler
    let env = H2ClientEnv "http2.golang.org" client
    runH2ClientM getExample env >>= print
    runH2ClientM (capitalize "shout me something back") env >>= print
    runH2ClientM getGoroutines env >>= go
  where
    go :: Either ServantError (ResultStream Text) -> IO ()
    go (Left err) = print err
    go (Right (ResultStream k)) = k $ \getResult ->
       let loop = do
            r <- getResult
            case r of
                Nothing -> return ()
                Just x -> print x >> loop
       in loop
    tlsParams = TLS.ClientParams {
          TLS.clientWantSessionResume    = Nothing
        , TLS.clientUseMaxFragmentLength = Nothing
        , TLS.clientServerIdentification = ("http2.golang.org", ByteString.pack $ show "443")
        , TLS.clientUseServerNameIndication = True
        , TLS.clientShared               = def
        , TLS.clientHooks                = def { TLS.onServerCertificate = \_ _ _ _ -> return []
                                               }
        , TLS.clientSupported            = def { TLS.supportedCiphers = TLS.ciphersuite_default }
        , TLS.clientDebug                = def
        }

