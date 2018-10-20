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

module Main where

import Network.HTTP2.Client.Servant

import           Data.IORef
import           Data.Foldable
import           Control.Exception (throwIO)
import           Control.Monad (unless)
import           Control.Monad.Catch (MonadCatch, MonadThrow)
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
import           Data.Text (Text)
import qualified Data.Text as Text
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
import           Data.Proxy

--- usage ---
--
data RawText
instance Accept RawText where
  contentType _ = "text/plain"
instance MimeRender RawText Text where
  mimeRender _ = fromStrict . Encoding.encodeUtf8
instance MimeUnrender RawText Text where
  mimeUnrender _ = pure . Encoding.decodeUtf8 . toStrict
instance MimeUnrender OctetStream Text where
  mimeUnrender _ = pure . Encoding.decodeUtf8 . toStrict

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

main :: IO ()
main = do
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
