{-# LANGUAGE TemplateHaskell #-}

-- | File/directory operations on logs.

module FileOps
       ( LogsHolder (..)
       , initHolder
       , addEntry
       ) where

import           Control.Concurrent  (MVar)
import           Control.Monad.Catch (throwM)
import qualified Data.List.NonEmpty  as NE
import qualified Data.Text           as T
import qualified Data.Text.IO        as TIO
import           Data.Time           (UTCTime, getCurrentTime)
import           Data.Time.Format    (defaultTimeLocale, formatTime, parseTimeM)
import           System.Directory    (createDirectory, createDirectoryIfMissing,
                                      doesFileExist)
import           System.FilePath     ((</>))
import           Universum

import           Exception           (ReportServerException (MalformedIndex))
import           Util                (withFileWriteLifted)


indexFileName :: FilePath
indexFileName = "index.log"

dateFormat :: [Char]
dateFormat = "%F_%T_%Z"

data LogsHolder = LogsHolder
    { lhDir    :: FilePath
    , lhIndex  :: FilePath
    , lhLastIx :: MVar Int
    }

-- | Parses single line of index -- returns index id, time item created
-- on and subdir name.
parseIndexEntry :: Text -> Either Text (Int, UTCTime, FilePath)
parseIndexEntry line = case T.splitOn "," line of
    [a,b,c] -> do
        ix <- mToE ("Couldn't read index: " <> a) $ readMaybe $ T.unpack a
        time <-
            mToE ("Couldn't parse utctime: " <> b) $
            parseTimeM True defaultTimeLocale dateFormat (T.unpack b)
        let fpath = T.unpack c
        when ("/" `T.isInfixOf` c) $
            Left $ "Filepath has '/' inside it: " <> c
        pure $ (ix, time, fpath)
    _ -> Left $ "Expected csv with 3 argument, got: " <> line
  where
    mToE reason  =  maybe (Left reason) Right

-- | Initializes logs holder -- opens file, creates index.
initHolder :: FilePath -> IO LogsHolder
initHolder dir = do
    createDirectoryIfMissing True dir
    lastIx <- newMVar =<< ifM (doesFileExist filePath) onExist onCreate
    pure $ LogsHolder dir filePath lastIx
  where
    filePath = dir </> indexFileName
    onExist = do
        tlines <- T.lines <$> TIO.readFile filePath
        case NE.nonEmpty tlines of
            Nothing -> onCreate
            Just ne ->
                either failInit (pure . view _1) $
                parseIndexEntry $ NE.last ne
    onCreate = TIO.writeFile filePath "" $> 0
    failInit = throwM . MalformedIndex

-- | Given logs holder and list of (filename,content), create a new
-- logs dir, dump files there and place an entry to index.
addEntry :: LogsHolder -> [(Text, Text)] -> IO ()
addEntry LogsHolder{..} files = do
    putText "Adding entry 0"
    timestamp <-
        formatTime defaultTimeLocale dateFormat <$>
        getCurrentTime
    let dirname = "logs_" <> timestamp
    let fullDirname = lhDir </> dirname
    createDirectory fullDirname
    forM_ files $ \(fname,content) ->
        TIO.writeFile (fullDirname </> T.unpack fname) content
    modifyMVar_ lhLastIx $ \i -> do
        let entry =
                T.intercalate ","
                ([show i, T.pack timestamp, T.pack dirname])
                <> "\n"
        withFileWriteLifted lhIndex $ TIO.appendFile lhIndex entry
        pure $ i + 1