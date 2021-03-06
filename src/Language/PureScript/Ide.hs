{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PackageImports        #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}

module Language.PureScript.Ide where

import           Prelude                            ()
import           Prelude.Compat

import           Control.Monad.Error.Class
import           Control.Monad.IO.Class
import           "monad-logger" Control.Monad.Logger
import           Control.Monad.Reader.Class
import           Data.Foldable
import qualified Data.Map.Lazy                      as M
import           Data.Maybe                         (catMaybes, mapMaybe)
import           Data.Monoid
import           Data.Text                          (Text)
import qualified Data.Text                          as T
import qualified Language.PureScript.Ide.CaseSplit  as CS
import           Language.PureScript.Ide.Command
import           Language.PureScript.Ide.Completion
import           Language.PureScript.Ide.Error
import           Language.PureScript.Ide.Externs
import           Language.PureScript.Ide.Filter
import           Language.PureScript.Ide.Matcher
import           Language.PureScript.Ide.Pursuit
import           Language.PureScript.Ide.Reexports
import           Language.PureScript.Ide.SourceFile
import           Language.PureScript.Ide.State
import           Language.PureScript.Ide.Types
import           System.Directory
import           System.FilePath
import           System.Exit


handleCommand :: (PscIde m, MonadLogger m, MonadError PscIdeError m) =>
                 Command -> m Success
handleCommand (Load modules deps) =
    loadModulesAndDeps modules deps
handleCommand (Type search filters) =
    findType search filters
handleCommand (Complete filters matcher) =
    findCompletions filters matcher
handleCommand (Pursuit query Package) =
    findPursuitPackages query
handleCommand (Pursuit query Identifier) =
    findPursuitCompletions query
handleCommand (List LoadedModules) =
    printModules
handleCommand (List AvailableModules) =
    listAvailableModules
handleCommand (List (Imports fp)) =
    importsForFile fp
handleCommand (CaseSplit l b e wca t) =
    caseSplit l b e wca t
handleCommand (AddClause l wca) =
    pure $ addClause l wca
handleCommand Cwd =
    TextResult . T.pack <$> liftIO getCurrentDirectory
handleCommand Quit = liftIO exitSuccess

findCompletions :: (PscIde m, MonadLogger m) =>
                   [Filter] -> Matcher -> m Success
findCompletions filters matcher =
  CompletionResult . getCompletions filters matcher <$> getAllModulesWithReexports

findType :: (PscIde m, MonadLogger m) =>
            DeclIdent -> [Filter] -> m Success
findType search filters =
  CompletionResult . getExactMatches search filters <$> getAllModulesWithReexports

findPursuitCompletions :: (MonadIO m, MonadLogger m) =>
                          PursuitQuery -> m Success
findPursuitCompletions (PursuitQuery q) =
  PursuitResult <$> liftIO (searchPursuitForDeclarations q)

findPursuitPackages :: (MonadIO m, MonadLogger m) =>
                       PursuitQuery -> m Success
findPursuitPackages (PursuitQuery q) =
  PursuitResult <$> liftIO (findPackagesForModuleIdent q)

loadExtern ::(PscIde m, MonadLogger m, MonadError PscIdeError m) =>
             FilePath -> m ()
loadExtern fp = do
  m <- readExternFile fp
  insertModule m

printModules :: (PscIde m) => m Success
printModules = printModules' <$> getPscIdeState

printModules' :: M.Map ModuleIdent [ExternDecl] -> Success
printModules' = ModuleList . M.keys

listAvailableModules :: PscIde m => m Success
listAvailableModules = do
  outputPath <- confOutputPath . envConfiguration <$> ask
  liftIO $ do
    cwd <- getCurrentDirectory
    dirs <- getDirectoryContents (cwd </> outputPath)
    return (ModuleList (listAvailableModules' dirs))

listAvailableModules' :: [FilePath] -> [Text]
listAvailableModules' dirs =
  let cleanedModules = filter (`notElem` [".", ".."]) dirs
  in map T.pack cleanedModules

caseSplit :: (PscIde m, MonadLogger m, MonadError PscIdeError m) =>
  Text -> Int -> Int -> CS.WildcardAnnotations -> Text -> m Success
caseSplit l b e csa t = do
  patterns <- CS.makePattern l b e csa <$> CS.caseSplit t
  pure (MultilineTextResult patterns)

addClause :: Text -> CS.WildcardAnnotations -> Success
addClause t wca = MultilineTextResult (CS.addClause t wca)

importsForFile :: (MonadIO m, MonadLogger m, MonadError PscIdeError m) =>
                  FilePath -> m Success
importsForFile fp = do
  imports <- getImportsForFile fp
  pure (ImportList imports)

-- | The first argument is a set of modules to load. The second argument
--   denotes modules for which to load dependencies
loadModulesAndDeps :: (PscIde m, MonadLogger m, MonadError PscIdeError m) =>
                     [ModuleIdent] -> [ModuleIdent] -> m Success
loadModulesAndDeps mods deps = do
  r1 <- mapM loadModule (mods ++ deps)
  r2 <- mapM loadModuleDependencies deps
  let moduleResults = T.concat r1
  let dependencyResults = T.concat r2
  pure (TextResult (moduleResults <> ", " <> dependencyResults))

loadModuleDependencies ::(PscIde m, MonadLogger m, MonadError PscIdeError m) =>
                         ModuleIdent -> m Text
loadModuleDependencies moduleName = do
  m <- getModule moduleName
  case getDependenciesForModule <$> m of
    Just deps -> do
      mapM_ loadModule deps
      -- We need to load the modules, that get reexported from the dependencies
      depModules <- catMaybes <$> mapM getModule deps
      -- What to do with errors here? This basically means a reexported dependency
      -- doesn't exist in the output/ folder
      traverse_ loadReexports depModules
      pure ("Dependencies for " <> moduleName <> " loaded.")
    Nothing -> throwError (ModuleNotFound moduleName)

loadReexports :: (PscIde m, MonadLogger m, MonadError PscIdeError m) =>
                Module -> m [ModuleIdent]
loadReexports m = case getReexports m of
  [] -> pure []
  exportDeps -> do
    -- I'm fine with this crashing on a failed pattern match.
    -- If this ever fails I'll need to look at GADTs
    let reexports = map (\(Export mn) -> mn) exportDeps
    $(logDebug) ("Loading reexports for module: " <> fst m <>
                 " reexports: " <> T.intercalate ", " reexports)
    traverse_ loadModule reexports
    exportDepsModules <- catMaybes <$> traverse getModule reexports
    exportDepDeps <- traverse loadReexports exportDepsModules
    return $ concat exportDepDeps

getDependenciesForModule :: Module -> [ModuleIdent]
getDependenciesForModule (_, decls) = mapMaybe getDependencyName decls
  where getDependencyName (Dependency dependencyName _ _) = Just dependencyName
        getDependencyName _ = Nothing

loadModule :: (PscIde m, MonadLogger m, MonadError PscIdeError m) =>
              ModuleIdent -> m Text
loadModule "Prim" = pure "Prim won't be loaded"
loadModule mn = do
  path <- filePathFromModule mn
  loadExtern path
  $(logDebug) ("Loaded extern file at: " <> T.pack path)
  pure ("Loaded extern file at: " <> T.pack path)

filePathFromModule :: (PscIde m, MonadError PscIdeError m) =>
                      ModuleIdent -> m FilePath
filePathFromModule moduleName = do
  outputPath <- confOutputPath . envConfiguration <$> ask
  cwd <- liftIO getCurrentDirectory
  let path = cwd </> outputPath </> T.unpack moduleName </> "externs.json"
  ex <- liftIO $ doesFileExist path
  if ex
    then pure path
    else throwError (ModuleFileNotFound moduleName)

-- | Taken from Data.Either.Utils
maybeToEither :: MonadError e m =>
                 e                      -- ^ (Left e) will be returned if the Maybe value is Nothing
              -> Maybe a                -- ^ (Right a) will be returned if this is (Just a)
              -> m a
maybeToEither errorval Nothing = throwError errorval
maybeToEither _ (Just normalval) = return normalval
