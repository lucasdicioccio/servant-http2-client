{-# LANGUAGE DataKinds      #-}
{-# LANGUAGE TypeOperators  #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE InstanceSigs   #-}
{-# LANGUAGE GeneralizedNewtypeDeriving   #-}
{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE MultiParamTypeClasses   #-}
module Lib
    ( someFunc
    ) where

import           Control.Exception (throwIO)
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Except
import           Control.Monad.Error.Class   (MonadError (..))
import           Control.Monad.Reader
import           Data.Aeson (eitherDecode)
import           Data.Binary.Builder (toLazyByteString)
import           Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as ByteString
import           Data.ByteString.Lazy (fromStrict, toStrict)
import           Data.Default.Class (def)
import           Data.Foldable (toList)
import           Data.Sequence (fromList)
import           Data.Text.Encoding as Encoding
import           GHC.Generics
import           Servant.API
import           Servant.Client.Core
import           Servant.Client.Core.Internal.RunClient
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

performRequest :: Request -> H2ClientM Response
performRequest req = do
    H2ClientEnv authority http2client <- ask
    let icfc = _incomingFlowControl http2client
    let ocfc = _outgoingFlowControl http2client
    let baseHeaders =
            [ (":method", requestMethod req)
            , (":scheme", "https")
            , (":path", toStrict $ toLazyByteString $ requestPath req)
            , (":authority", authority)
            , ("Accept", ByteString.intercalate "," $ toList $ fmap renderHeader $ requestAccept req)
            , ("User-Agent", "servant-http2-client/dev")
            ]
    let reqHeaders = [(CI.original h, hv) | (h,hv) <- toList (requestHeaders req)]
    let (body,bodyheaders) = case requestBody req of
            Nothing -> ("",[])
            Just (RequestBodyBS bs, ct)  ->
                (bs,[ ("Content-Type", renderHeader ct)
                    , ("Content-Length", ByteString.pack $ show $ ByteString.length bs)
                    ])
            Just (RequestBodyLBS lbs, ct) -> let bs = toStrict lbs in
                (bs,[ ("Content-Type", renderHeader ct)
                    , ("Content-Length", ByteString.pack $ show $ ByteString.length bs)
                    ])
    let headersPairs = baseHeaders <> reqHeaders <> bodyheaders
    let headersFlags = id
    let resetPushPromises _ pps _ _ _ = _rst pps RefusedStream
    http2rsp <- liftIO $ withHttp2Stream http2client $ \stream ->
        let initStream =
                headers stream headersPairs headersFlags
            handler isfc osfc = do
                upload body setEndStream http2client ocfc stream osfc
                streamResult <- waitStream stream icfc resetPushPromises
                pure $ fromStreamResult streamResult
        in (StreamDefinition initStream handler)
    let response = case http2rsp of
            Right (Right (hdrs,body,_))
                | let Just status = readMaybe . ByteString.unpack =<< lookup ":status" hdrs ->
                        Response (Status status "") (fromList [ (CI.mk h, hv) | (h,hv) <- hdrs ]) http20 (fromStrict body)
    pure response

performStreamingRequest :: Request -> H2ClientM StreamingResponse
performStreamingRequest req = undefined

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
  :<|> "goroutines" :> Get '[RawText] Text
  :<|> "ECHO" :> ReqBody '[RawText] Text :> Put '[OctetStream] Text

myApi :: Proxy Http2Golang
myApi = Proxy

getExample :: H2ClientM Text
getGoroutines :: H2ClientM Text
capitalize :: Text -> H2ClientM Text
getExample :<|> getGoroutines :<|> capitalize = h2client myApi

someFunc :: IO ()
someFunc = do
    frameConn <- newHttp2FrameConnection "http2.golang.org" 443 (Just tlsParams)
    client <- newHttp2Client frameConn 8192 8192 [] defaultGoAwayHandler ignoreFallbackHandler
    let env = H2ClientEnv "http2.golang.org" client
    runH2ClientM getExample env >>= print
    runH2ClientM (capitalize "shout me something back") env >>= print
    runH2ClientM getGoroutines env >>= print
  where
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

