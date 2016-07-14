{-# LANGUAGE BangPatterns, OverloadedStrings #-}

-- | Middleware for server push learning dependency based on Referer:.
module Network.Wai.Middleware.Push.Referer (
    pushOnReferer
  , MakePushPromise
  , defaultMakePushPromise
  , URLPath
  ) where

import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.ByteString.Internal (ByteString(..), memchr)
import Data.IORef
import Data.Maybe (isNothing)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Word (Word8)
import Data.Word8
import Foreign.ForeignPtr (withForeignPtr, ForeignPtr)
import Foreign.Ptr (Ptr, plusPtr, minusPtr, nullPtr)
import Foreign.Storable (peek)
import Network.HTTP.Types (Status(..))
import Network.Wai
import Network.Wai.Handler.Warp
import Network.Wai.Internal (Response(..))
import System.IO.Unsafe (unsafePerformIO)

import qualified Network.Wai.Middleware.Push.LRU as LRU

-- $setup
-- >>> :set -XOverloadedStrings

-- | Making a push promise based on Referer:,
--   path to be pushed and file to be pushed.
--   If the middleware should push this file in the next time when
--   the page of Referer: is accessed,
--   this function should return 'Just'.
--   If 'Nothing' is returned,
--   the middleware learns nothing.
type MakePushPromise = URLPath  -- ^ path in referer
                    -> URLPath  -- ^ path to be pushed
                    -> FilePath -- ^ file to be pushed
                    -> IO (Maybe PushPromise)

-- | Type for URL path.
type URLPath = ByteString

type Cache = LRU.LRUCache URLPath (Set PushPromise)

emptyCache :: Cache
emptyCache = LRU.empty 100 -- fixme

lruCache :: IORef Cache
lruCache = unsafePerformIO $ newIORef emptyCache
{-# NOINLINE lruCache #-}

insert :: (URLPath,PushPromise) -> Cache -> Cache
insert (path,pp) m = LRU.alter ins path m
  where
    ins Nothing    = (False, Just $! S.singleton pp)
    ins (Just set) = (True,  Just $! S.insert pp set)

-- | The middleware to push files based on Referer:.
--   Learning strategy is implemented in the first argument.
pushOnReferer :: MakePushPromise -> Middleware
pushOnReferer func app req sendResponse = app req $ \res -> do
    let !path = rawPathInfo req
    cache <- readIORef lruCache
    case LRU.lookup path cache of
        Nothing -> case requestHeaderReferer req of
            Nothing      -> return ()
            Just referer -> case res of
                ResponseFile (Status 200 "OK") _ file Nothing -> do
                    (mauth,refPath) <- parseUrl referer
                    when (isNothing mauth
                       || requestHeaderHost req == mauth) $ do
                        when (path /= refPath) $ do -- just in case
                            mpp <- func refPath path file
                            case mpp of
                                Nothing -> return ()
                                Just pp -> atomicModifyIORef' lruCache $ \c ->
                                  (insert (refPath,pp) c, ())
                _ -> return ()
        Just (pset,cache') -> do
            writeIORef lruCache cache'
            let !ps = S.toList pset
                !h2d = defaultHTTP2Data { http2dataPushPromise = ps}
            setHTTP2Data req (Just h2d)
    sendResponse res

-- | Learn if the file to be pushed is CSS (.css) or JavaScript (.js) file
--   AND the Referer: ends with \"/\" or \".html\" or \".htm\".
defaultMakePushPromise :: MakePushPromise
defaultMakePushPromise refPath path file
  | isHTML refPath = case getCT path of
      Nothing -> return Nothing
      Just ct -> do
          let pp = defaultPushPromise {
                       promisedPath = path
                     , promisedFile = file
                     , promisedResponseHeaders = [("content-type", ct)
                                                 ,("x-http2-push", refPath)]
                     }
          return $ Just pp
  | otherwise = return Nothing

getCT :: URLPath -> Maybe ByteString
getCT p
  | ".js"  `BS.isSuffixOf` p = Just "application/javascript"
  | ".css" `BS.isSuffixOf` p = Just "text/css"
  | otherwise                = Nothing

isHTML :: URLPath -> Bool
isHTML p = ("/" `BS.isSuffixOf` p)
        || (".html" `BS.isSuffixOf` p)
        || (".htm" `BS.isSuffixOf` p)

-- |
--
-- >>> parseUrl ""
-- (Nothing,"")
-- >>> parseUrl "/"
-- (Nothing,"/")
-- >>> parseUrl "ht"
-- (Nothing,"")
-- >>> parseUrl "http://example.com/foo/bar/"
-- (Just "example.com","/foo/bar/")
-- >>> parseUrl "https://www.example.com/path/to/dir/"
-- (Just "www.example.com","/path/to/dir/")
-- >>> parseUrl "http://www.example.com:8080/path/to/dir/"
-- (Just "www.example.com:8080","/path/to/dir/")
-- >>> parseUrl "//www.example.com:8080/path/to/dir/"
-- (Just "www.example.com:8080","/path/to/dir/")
-- >>> parseUrl "/path/to/dir/"
-- (Nothing,"/path/to/dir/")

parseUrl :: ByteString -> IO (Maybe ByteString, URLPath)
parseUrl bs@(PS fptr0 off len)
  | len == 0 = return (Nothing, "")
  | len == 1 = return (Nothing, bs)
  | otherwise = withForeignPtr fptr0 $ \ptr0 -> do
      let begptr = ptr0 `plusPtr` off
          limptr = begptr `plusPtr` len
      parseUrl' fptr0 ptr0 begptr limptr len

parseUrl' :: ForeignPtr Word8 -> Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> Int
          -> IO (Maybe ByteString, URLPath)
parseUrl' fptr0 ptr0 begptr limptr len0 = do
      w0 <- peek begptr
      if w0 == _slash then do
          w1 <- peek $ begptr `plusPtr` 1
          if w1 == _slash  then
              doubleSlashed begptr len0
            else
              slashed begptr len0 Nothing
        else do
          colonptr <- memchr begptr _colon $ fromIntegral len0
          if colonptr == nullPtr then
              return (Nothing, "")
            else do
              let !authptr = colonptr `plusPtr` 1
              doubleSlashed authptr (limptr `minusPtr` authptr)
  where
    -- // / ?
    doubleSlashed :: Ptr Word8 -> Int -> IO (Maybe ByteString, URLPath)
    doubleSlashed ptr len
      | len < 2  = return (Nothing, "")
      | otherwise = do
          let ptr1 = ptr `plusPtr` 2
          pathptr <- memchr ptr1 _slash $ fromIntegral len
          if pathptr == nullPtr then
              return (Nothing, "")
            else do
              let !auth = bs ptr0 ptr1 pathptr
              slashed pathptr (limptr `minusPtr` pathptr) (Just auth)

    -- / ?
    slashed :: Ptr Word8 -> Int -> Maybe ByteString -> IO (Maybe ByteString, URLPath)
    slashed ptr len mauth = do
        questionptr <- memchr ptr _question $ fromIntegral len
        if questionptr == nullPtr then do
            let !path = bs ptr0 ptr limptr
            return (mauth, path)
          else do
            let !path = bs ptr0 ptr questionptr
            return (mauth, path)
    bs p0 p1 p2 = path
      where
        !off = p1 `minusPtr` p0
        !siz = p2 `minusPtr` p1
        !path = PS fptr0 off siz

