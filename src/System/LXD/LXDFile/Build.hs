{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}
-- | Build LXD images using lxdfiles.
module System.LXD.LXDFile.Build (
  build
) where

import Prelude hiding (writeFile)

import Control.Monad.Catch
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, runReaderT, ask)
import Control.Monad.Trans (lift)

import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy (writeFile)
import Data.Coerce (coerce)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import qualified Data.Attoparsec.Text as A

import Network.LXD.Client.Commands
    (HasClient(..), ContainerName(..),
     ImageCreateRequest(..), ImageSource(..), LocalContainer(..), ImageAlias(..), imageCreateRequest,
     containerCreateRequest,
     lxcStop, lxcImageCreate, lxcDelete, lxcCreate, lxcStart, lxcFileMkdir, lxcFilePush)

import qualified System.LXD.Client.Config as LXC

import System.IO.Error (userError)
import System.Random (randomIO)

import Filesystem.Path.CurrentOS (decodeString)
import Turtle (rm, sleep)

import Language.LXDFile (LXDFile(..))
import System.LXD.LXDFile.ScriptAction (scriptActions, runScriptAction, tmpfile)
import System.LXD.LXDFile.Types (parseImage, containerSourceFromImage)
import System.LXD.LXDFile.Utils.Line (echoT, echoS)
import System.LXD.LXDFile.Utils.Text (showT)

data BuildCtx = BuildCtx { lxdfile :: LXDFile
                         , imageName :: Text
                         , context :: FilePath
                         , buildContainer :: ContainerName }

build :: HasClient m => LXC.Config -> LXDFile -> Text -> FilePath -> m ()
build lxcCfg lxdfile'@LXDFile{..} imageName' context' = do
    container <- launch
    let ctx = BuildCtx { lxdfile = lxdfile'
                       , imageName = imageName'
                       , context = context'
                       , buildContainer = container }
    flip runReaderT ctx $ do
        sleep 5.0

        lift $ mapM_ (flip runReaderT container . runScriptAction context') $ scriptActions actions
        includeLXDFile

        echoT $ "Stopping " <> showT container
        lift $ lxcStop container False

        echoT $ "Publishing to " <> imageName'
        let alias = ImageAlias (T.unpack imageName')
                               (fromMaybe "" description)
                               Nothing
            req' = imageCreateRequest
                 . ImageSourceLocalContainer
                 . LocalContainer
                 $ container
            req = req' { imageCreateRequestAliases = [alias] }

        lift $ lxcImageCreate req
        lift $ lxcDelete container
  where
    launch :: HasClient m => m ContainerName
    launch = do
        img <- case A.parseOnly parseImage (T.pack baseImage) of
            Left err -> throwM . userError $ "Could not parse base image: " ++ baseImage ++ err
            Right i -> case containerSourceFromImage lxcCfg i of
                Left e -> throwM $ userError e
                Right x -> return x
        n <- ContainerName . ("lxdfile-" <>) . UUID.toString <$> liftIO randomIO
        echoS $ "Launching temporary container " <> coerce n

        let req = containerCreateRequest (coerce n) img
        lxcCreate req
        lxcStart n

        return n

includeLXDFile :: HasClient m => ReaderT BuildCtx m ()
includeLXDFile = do
    c <- buildContainer <$> ask
    file <- tmpfile "lxdfile-metadata-lxdfile"
    ask >>= liftIO . writeFile file . encodePretty . lxdfile
    lift $ lxcFileMkdir c "/etc/lxdfile" True
    lift $ lxcFilePush c file "/etc/lxdfile/lxdfile"
    rm (decodeString file)
