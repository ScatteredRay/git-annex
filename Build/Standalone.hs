{- Makes standalone bundle.
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Main where

import Control.Applicative
import Control.Monad.IfElse
import System.Environment
import Data.Maybe
import System.FilePath
import System.Directory
import System.IO
import Control.Monad
import Data.List
import Build.BundledPrograms

import Utility.PartialPrelude
import Utility.Directory
import Utility.Process
import Utility.Monad
import Utility.SafeCommand
import Utility.Path

progDir :: FilePath -> FilePath
#ifdef darwin_HOST_OS
progDir topdir = topdir
#else
progDir topdir = topdir </> "bin"
#endif

installProg :: FilePath -> FilePath -> IO (FilePath, FilePath)
installProg dir prog = searchPath prog >>= go
  where
	go Nothing = error $ "cannot find " ++ prog ++ " in PATH"
	go (Just f) = do
		let dest = dir </> takeFileName f
		unlessM (boolSystem "install" [File f, File dest]) $
			error $ "install failed for " ++ prog
		return (dest, f)

main = getArgs >>= go
  where
	go [] = error "specify topdir"
        go (topdir:_) = do
		let dir = progDir topdir
		createDirectoryIfMissing True dir
		installed <- forM bundledPrograms $ installProg dir
		writeFile "tmp/standalone-installed" (show installed)
