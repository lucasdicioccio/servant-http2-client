{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.HTTP2.Client.Servant (
    H2ClientM
  , runH2ClientM
  , H2ClientEnv (..)
  -- * generate functions
  , h2client
  ) where

import           Data.IORef (newIORef, readIORef, writeIORef)
import           Data.Foldable (traverse_)
import           Control.Exception (throwIO)
import           Control.Monad (unless, when, (>=>))
import           Control.Monad.Catch (MonadCatch, MonadThrow)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Monad.Trans.Except (ExceptT, runExceptT)
import           Control.Monad.Error.Class   (MonadError (..))
import           Control.Monad.Reader (MonadReader, ReaderT, ask, runReaderT)
import           Data.Binary.Builder (toLazyByteString)
import           Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as ByteString
import           Data.ByteString.Lazy (fromStrict, toStrict, toChunks)
import           Data.Foldable (toList)
import           Data.Proxy (Proxy(..))
import           Data.Sequence (fromList)
import qualified Data.Text as Text
import           GHC.Generics (Generic)
import           Network.HPACK (HeaderList)
import           Network.HTTP.Media.RenderHeader (renderHeader)
import           Network.HTTP2 (flags, setEndStream, testEndStream, payloadLength, toErrorCodeId, ErrorCodeId(RefusedStream))
import           Network.HTTP2.Client.Helpers (upload, waitStream, fromStreamResult)
import           Network.HTTP.Types.Status (Status(..))
import           Network.HTTP.Types.Version (http20)
import qualified Data.CaseInsensitive as CI
import           Text.Read (readMaybe)


import           Network.HTTP2.Client
import           Servant.Client.Core

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

-- | Construct a ByteSegments from a single ByteString.
onlySegment :: ByteString -> ByteSegments
onlySegment bs handle = handle (pure bs)

-- | Construct a ByteSegments from a lazy list of ByteString.
--
-- Since we expect the handler passed to ByteSegments to do some IO, empty
-- chunks are discarded to save on IOs.
multiSegments :: [ByteString] -> ByteSegments
multiSegments bss handle =
    traverse_ (handle . pure) (filter (not . ByteString.null) bss)

-- | Pulls data segments from ByteSegments and calls 'upload' on it.
sendSegments
  :: Http2Client
  -> Http2Stream
  -> OutgoingFlowControl
  -- ^ Connection
  -> OutgoingFlowControl
  -- ^ Stream
  -> ByteSegments
  -> IO ()
sendSegments http2client stream ocfc osfc segments =
    segments go
  where
    go getChunk = do
        dat <- getChunk
        upload dat id http2client ocfc stream osfc

-- | Prepare an HTTP2 request to a given server.
makeRequest
  :: ByteString
  -- ^ Server's Authority.
  -> Request
  -- ^ The HTTP request.
  -> IO (HeaderList, ByteSegments)
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
    pure (headersPairs, bodyIO)
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

resetPushPromises :: PushPromiseHandler
resetPushPromises _ pps _ _ _ = _rst pps RefusedStream

-- | Implementation of simple requests.
performRequest :: Request -> H2ClientM Response
performRequest req = do
    H2ClientEnv authority http2client <- ask
    let icfc = _incomingFlowControl http2client
    let ocfc = _outgoingFlowControl http2client
    let headersFlags = id

    (headersPairs, bodyIO) <- liftIO $ makeRequest authority req
    http2rsp <- liftIO $ withHttp2Stream http2client $ \stream ->
        let initStream =
                headers stream headersPairs headersFlags
            handler _ osfc = do
                sendSegments http2client stream ocfc osfc bodyIO
                sendData http2client stream setEndStream ""
                streamResult <- waitStream stream icfc resetPushPromises
                pure $ fromStreamResult streamResult
        in (StreamDefinition initStream handler)
    case http2rsp of
            Left (TooMuchConcurrency _) ->
                throwError $ Servant.Client.Core.ConnectionError "too many concurrent streams"
            Right (Right (hdrs,body,_))
                | let Just status = lookupStatus hdrs -> do
                    let response = mkResponse status hdrs body
                    unless (status >= 200 && status < 300) $
                        throwError $ FailureResponse response
                    pure response
                | otherwise -> do
                    let response = mkResponse 0 hdrs body
                    throwError $ DecodeFailure "no :status header" response
            Right (Left err) ->
                throwError $ Servant.Client.Core.ConnectionError $ "connection error: " <> (Text.pack $ show $ toErrorCodeId err)

mkResponse :: Int -> HeaderList -> ByteString -> Response
mkResponse status hdrs body =
    Response (Status status "")
             (fromList [ (CI.mk h, hv) | (h,hv) <- hdrs ])
             http20
             (fromStrict body)

lookupStatus :: HeaderList -> Maybe Int
lookupStatus = lookup ":status" >=> readMaybe . ByteString.unpack

replenishFlowControls
  :: IncomingFlowControl -> IncomingFlowControl -> Int -> IO ()
replenishFlowControls icfc isfc len = do
    _ <- _consumeCredit isfc len
    _addCredit isfc len
    _ <- _updateWindow isfc
    _ <- _consumeCredit icfc len
    _addCredit icfc len
    _ <- _updateWindow icfc
    pure ()

-- | Implementation of requests with streaming replies.
performStreamingRequest :: Request -> H2ClientM StreamingResponse
performStreamingRequest req = do
    H2ClientEnv authority http2client <- ask
    let icfc = _incomingFlowControl http2client
    let ocfc = _outgoingFlowControl http2client
    let headersFlags = id

    (headersPairs, bodyIO) <- liftIO $ makeRequest authority req
    ret <- liftIO $ withHttp2Stream http2client $ \stream ->
        let initStream =
                headers stream headersPairs headersFlags
            handler isfc osfc = do
                -- Send the request
                sendSegments http2client stream ocfc osfc bodyIO
                sendData http2client stream setEndStream ""
                -- Waits for headers and returns the response object to the
                -- caller.
                pure $ StreamingResponse (\handleGenResponse -> do
                    ev <- _waitEvent stream
                    case ev of
                        (StreamHeadersEvent fh hdrs) -> handleHeaders stream icfc isfc fh hdrs handleGenResponse
                        _ -> throwIO $ Servant.Client.Core.ConnectionError $ "unwanted event received in data stream" <> Text.pack (show ev)
                        )
        in (StreamDefinition initStream handler)
    case ret of
        Right streamingResp -> pure streamingResp
        Left (TooMuchConcurrency _) ->
            throwError $ Servant.Client.Core.ConnectionError "too many concurrent streams"
  where
    handleHeaders stream icfc isfc fh hdrs handleGenResponse
        | let Just status = lookupStatus hdrs = do
            isFinished <- newIORef False
            when (testEndStream $ flags fh) $
                writeIORef isFinished True
            let response = mkStreamResponse status hdrs isFinished stream icfc isfc
            unless (status >= 200 && status < 300) $ do
                wholeBody <- consumeBody stream icfc isfc
                let failResponse = mkResponse status hdrs wholeBody
                throwIO $ FailureResponse failResponse
            handleGenResponse response
        | otherwise = do
            wholeBody <- consumeBody stream icfc isfc
            let response = mkResponse 0 hdrs wholeBody
            throwIO $ DecodeFailure "no :status header" response

    -- | Helper to consume the whole response body when the status is not a 2xx.
    -- This consumption can itself fail.
    consumeBody stream icfc isfc = do
        (revBss,_) <- waitDataFrames stream icfc isfc []
        let bs = mconcat $ reverse revBss
        pure bs

    -- | Helper to iteratively eat all data frames.
    waitDataFrames stream icfc isfc xs = do
        ev <- _waitEvent stream
        case ev of
            StreamDataEvent fh x
                | testEndStream (flags fh) ->
                    return (x:xs, Nothing)
                | otherwise                -> do
                    replenishFlowControls icfc isfc (payloadLength fh)
                    waitDataFrames stream icfc isfc (x:xs)
            StreamPushPromiseEvent _ ppSid ppHdrs -> do
                _handlePushPromise stream ppSid ppHdrs resetPushPromises
                waitDataFrames stream icfc isfc xs
            StreamHeadersEvent _ hdrs ->
                return (xs, Just hdrs)
            _ -> throwIO $ Servant.Client.Core.ConnectionError $ "unwanted event received in data stream" <> Text.pack (show ev)

    -- | Function to get the next DATA chunk on a stream this function is
    -- stateful and modifies an IORef to remember that the stream is closed on
    -- the server side.
    -- Do not copy-paste this utility method unless you understand that the
    -- IORef must be entirely owned by this function.
    nextChunk isFinished stream icfc isfc = do
        done <- readIORef isFinished
        if done
        then pure ""
        else do
            ev <- _waitEvent stream
            case ev of
                (StreamDataEvent fh dat) -> do
                    replenishFlowControls icfc isfc (payloadLength fh)
                    when (testEndStream $ flags fh) $
                        writeIORef isFinished True
                    pure dat
                _ -> throwIO $ Servant.Client.Core.ConnectionError $ "unwanted event received in data stream" <> Text.pack (show ev)

    mkStreamResponse status hdrs isFinished stream icfc isfc =
        Response (Status status "") (fromList [ (CI.mk h, hv) | (h,hv) <- hdrs ]) http20 (nextChunk isFinished stream icfc isfc)

h2client :: HasClient H2ClientM api => Proxy api -> Client H2ClientM api
h2client api = api `clientIn` (Proxy :: Proxy H2ClientM)
