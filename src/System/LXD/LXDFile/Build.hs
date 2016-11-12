{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- | Build LXD images using lxdfiles.
module System.LXD.LXDFile.Build (
  build
) where

import Prelude hiding (writeFile)

import Control.Monad.Except (MonadError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, runReaderT, ask)

import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy (writeFile)
import Data.Either.Combinators (rightToMaybe)
import Data.Monoid ((<>))
import Data.Text (Text, pack, unpack)

import Text.Parsec (parse, many, noneOf, string)

import Filesystem.Path.CurrentOS (decodeString)
import Turtle (Fold(..), fold, echo, inproc, rm, format, (%))
import qualified Turtle as R

import Language.LXDFile (LXDFile(..))
import System.LXD.LXDFile.ScriptAction (HasContext(..), scriptActions, runScriptAction, tmpfile)
import System.LXD.LXDFile.Utils.Monad (orThrowM)
import System.LXD.LXDFile.Utils.Shell (HasContainer(..), lxc, lxcExec, lxcFilePush)

data BuildCtx = BuildCtx { lxdfile :: LXDFile
                         , imageName :: String
                         , context :: FilePath
                         , buildContainer :: Text }

build :: (MonadIO m, MonadError String m) => LXDFile -> String -> FilePath -> m ()
build lxdfile'@LXDFile{..} imageName' context' = do
    container <- launch `orThrowM` "error: could not launch container"
    let ctx = BuildCtx { lxdfile = lxdfile'
                       , imageName = imageName'
                       , context = context'
                       , buildContainer = container }
    flip runReaderT ctx $ do
        echo $ "Building " <> pack imageName' <> " in " <> container

        mapM_ runScriptAction $ scriptActions actions
        includeLXDFile

        echo $ "Stopping " <> container
        lxc ["stop", container]

        echo $ "Publishing to " <> pack imageName'
        case description of
            Nothing ->   lxc ["publish", container, format ("--alias=" % R.s) (pack imageName')]
            Just desc -> lxc ["publish", container, format ("--alias=" % R.s) (pack imageName'), format ("description=" % R.s) (pack desc)]
        lxc ["delete", container]
  where
    launch :: MonadIO m => m (Maybe Text)
    launch = fold (inproc "lxc" ["launch", pack baseImage] mempty) $
        Fold selectLaunchName Nothing id
    selectLaunchName (Just x) _ = Just x
    selectLaunchName _        x = parseLaunch x
    parseLaunch = (pack <$>) . rightToMaybe . parse (string "Creating " *> many (noneOf " ")) "" . unpack

includeLXDFile :: (MonadIO m, MonadError String m, MonadReader BuildCtx m) => m ()
includeLXDFile = do
    file <- tmpfile "lxdfile-metadata-lxdfile"
    ask >>= liftIO . writeFile file . encodePretty . lxdfile
    lxcExec ["mkdir", "-p", "/etc/lxdfile"]
    lxcFilePush "0644" file "/etc/lxdfile/lxdfile"
    rm (decodeString file)

instance MonadReader BuildCtx m => HasContainer m where
    askContainer = buildContainer <$> ask

instance MonadReader BuildCtx m => HasContext m where
    askContext = context <$> ask
