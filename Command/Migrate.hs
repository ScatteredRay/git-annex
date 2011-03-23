{- git-annex command
 -
 - Copyright 2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Migrate where

import Control.Monad.State (liftIO)
import Control.Monad (unless)
import System.Posix.Files
import System.Directory

import Command
import qualified Annex
import qualified Backend
import Locations
import Types
import Content
import Messages
import qualified Command.Add

command :: [Command]
command = [repoCommand "migrate" paramPath seek "switch data to different backend"]

seek :: [CommandSeek]
seek = [withBackendFilesInGit start]

start :: CommandStartBackendFile
start (file, b) = isAnnexed file $ \(key, oldbackend) -> do
	exists <- inAnnex key
	newbackend <- choosebackend b
	if (newbackend /= oldbackend) && exists
		then do
			showStart "migrate" file
			return $ Just $ perform file key newbackend
		else
			return Nothing
	where
		choosebackend Nothing = do
			backends <- Backend.list
			return $ head backends
		choosebackend (Just backend) = return backend

perform :: FilePath -> Key -> Backend Annex -> CommandPerform
perform file oldkey newbackend = do
	g <- Annex.gitRepo

	-- Store the old backend's cached key in the new backend
	-- (the file can't be stored as usual, because it's already a symlink).
	-- The old backend's key is not dropped from it, because there may
	-- be other files still pointing at that key.
	let src = gitAnnexLocation g oldkey
	stored <- Backend.storeFileKey src $ Just newbackend
	case stored of
		Nothing -> return Nothing
		Just (newkey, _) -> do
			ok <- getViaTmpUnchecked newkey $ \t -> do
				-- Make a hard link to the old backend's
				-- cached key, to avoid wasting disk space.
				exists <- liftIO $ doesFileExist t
				unless exists $ liftIO $ createLink src t
				return True
			if ok
				then do
					-- Update symlink to use the new key.
					liftIO $ removeFile file
					return $ Just $ Command.Add.cleanup file newkey
				else return Nothing
