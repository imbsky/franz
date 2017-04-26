{-# LANGUAGE RecordWildCards, LambdaCase, OverloadedStrings, ViewPatterns, BangPatterns #-}
module Database.Liszt.Server where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad
import Data.Binary as B
import Data.Binary.Get as B
import Data.Binary.Put as B
import Data.Int
import Data.Semigroup
import Data.String
import Database.Liszt.Types
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.IntMap.Strict as M
import qualified Network.WebSockets as WS
import System.Directory
import System.IO

foldAlt :: Alternative f => Maybe a -> f a
foldAlt (Just a) = pure a
foldAlt Nothing = empty

data System = System
    { vPayload :: TVar (M.IntMap (B.ByteString, Int64))
    -- A collection of payloads which are not available on disk.
    , vIndices :: TVar (M.IntMap Int64)
    }

handleConsumer :: FilePath
  -> System
  -> WS.Connection -> IO ()
handleConsumer path System{..} conn = do
  -- start from the beginning of the stream
  vOffset <- newTVarIO Nothing

  let getPos = readTVar vOffset >>= \case
        Nothing -> do
          m <- readTVar vIndices
          (ofs'@(_, pos), _) <- foldAlt $ M.minViewWithKey m
          writeTVar vOffset (Just ofs')
          return $ Left (0, pos)
        Just (ofs, pos) -> do
          m <- readTVar vIndices
          case M.lookupGT ofs m of
            Just op@(_, pos') -> do
              writeTVar vOffset (Just op)
              return $ Left (pos, pos')
            Nothing -> M.lookupGT ofs <$> readTVar vPayload >>= \case
              Just (ofs', (bs, pos')) -> do
                writeTVar vOffset $ Just (ofs', pos')
                return $ Right bs
              Nothing -> retry

  let send (Left (pos, pos')) = withBinaryFile path ReadMode $ \h -> do
        hSeek h AbsoluteSeek (fromIntegral pos)
        bs <- B.hGet h $ fromIntegral $ pos' - pos
        WS.sendBinaryData conn bs
      send (Right bs) = WS.sendBinaryData conn bs

  forever $ do
    req <- WS.receiveData conn
    case decodeOrFail req of
      Right (_, _, r) -> case r of
        Blocking -> atomically getPos >>= send
        NonBlocking -> join $ send <$> atomically getPos
          <|> pure (WS.sendTextData conn ("EOF" :: BL.ByteString))
        Seek ofs -> atomically $ do
          m <- readTVar vIndices
          ofsPos <- foldAlt $ M.lookupLE (fromIntegral ofs) m
          writeTVar vOffset (Just ofsPos)
      Left (_, _, e) -> WS.sendClose conn (fromString e :: B.ByteString)

handleProducer :: System
  -> WS.Connection
  -> IO ()
handleProducer System{..} conn = forever $ do
  reqBS <- WS.receiveData conn
  case runGetOrFail get reqBS of
    Right (BL.toStrict -> !content, _, req) -> atomically $ do
      m <- readTVar vPayload
      maxOfs <- case M.maxViewWithKey m of
        Just ((k, (_, p)), _) -> return $ Just (k, p)
        Nothing -> fmap fst <$> M.maxViewWithKey <$> readTVar vIndices

      ofs <- case req of
        Write o
          | maybe True ((o >) . fromIntegral . fst) maxOfs -> return $ fromIntegral o
          | otherwise -> fail "Monotonicity violation"
        WriteSeqNo -> return $ maybe 0 (succ . fromIntegral . fst) maxOfs

      let !pos' = maybe 0 snd maxOfs + fromIntegral (B.length content)

      modifyTVar' vPayload $ M.insert ofs (content, pos')

    Left _ -> WS.sendClose conn ("Malformed request" :: B.ByteString)

loadIndices :: FilePath -> IO (M.IntMap Int64)
loadIndices path = doesFileExist path >>= \case
  False -> return M.empty
  True -> do
    n <- (`div`16) <$> fromIntegral <$> getFileSize path
    bs <- BL.readFile path
    return $! M.fromAscList $ runGet (replicateM n $ (,) <$> get <*> get) bs

openLisztServer :: FilePath -> IO WS.ServerApp
openLisztServer path = do
  let ipath = path ++ ".indices"
  let ppath = path ++ ".payload"

  vIndices <- loadIndices ipath >>= newTVarIO

  vPayload <- newTVarIO M.empty

  -- synchronise payloads
  _ <- forkIO $ forever $ do
    m <- atomically $ do
      w <- readTVar vPayload
      when (M.null w) retry
      return w

    -- TODO: handle exceptions
    h <- openBinaryFile ppath AppendMode
    mapM_ (B.hPut h . fst) m
    hClose h

    BL.appendFile ipath
      $ B.runPut $ forM_ (M.toList m) $ \(k, (_, p)) -> B.put k >> B.put p

    atomically $ do
      modifyTVar' vIndices $ M.union (fmap snd m)
      modifyTVar' vPayload $ flip M.difference m

  let sys = System{..}

  return $ \pending -> case WS.requestPath (WS.pendingRequest pending) of
    "read" -> WS.acceptRequest pending >>= handleConsumer ppath sys
    "write" -> WS.acceptRequest pending >>= handleProducer sys
    p -> WS.rejectRequest pending ("Bad request: " <> p)
