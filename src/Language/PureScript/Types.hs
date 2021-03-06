{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Data types for types
--
module Language.PureScript.Types where

import Prelude ()
import Prelude.Compat

import Data.List (nub)
import Data.Maybe (fromMaybe)
import qualified Data.Aeson as A
import qualified Data.Aeson.TH as A

import Control.Arrow (second)
import Control.Monad ((<=<))

import Language.PureScript.Names
import Language.PureScript.Kinds
import Language.PureScript.Traversals
import Language.PureScript.AST.SourcePos

-- |
-- An identifier for the scope of a skolem variable
--
newtype SkolemScope = SkolemScope { runSkolemScope :: Int }
  deriving (Show, Read, Eq, Ord, A.ToJSON, A.FromJSON)

-- |
-- The type of types
--
data Type
  -- |
  -- A unification variable of type Type
  --
  = TUnknown Int
  -- |
  -- A named type variable
  --
  | TypeVar String
  -- |
  -- A type wildcard, as would appear in a partial type synonym
  --
  | TypeWildcard
  -- |
  -- A type constructor
  --
  | TypeConstructor (Qualified (ProperName 'TypeName))
  -- |
  -- A type application
  --
  | TypeApp Type Type
  -- |
  -- Forall quantifier
  --
  | ForAll String Type (Maybe SkolemScope)
  -- |
  -- A type with a set of type class constraints
  --
  | ConstrainedType [Constraint] Type
  -- |
  -- A skolem constant
  --
  | Skolem String Int SkolemScope (Maybe SourceSpan)
  -- |
  -- An empty row
  --
  | REmpty
  -- |
  -- A non-empty row
  --
  | RCons String Type Type
  -- |
  -- A type with a kind annotation
  --
  | KindedType Type Kind
  --
  -- |
  -- A placeholder used in pretty printing
  --
  | PrettyPrintFunction Type Type
  -- |
  -- A placeholder used in pretty printing
  --
  | PrettyPrintObject Type
  -- |
  -- A placeholder used in pretty printing
  --
  | PrettyPrintForAll [String] Type
  deriving (Show, Read, Eq, Ord)

-- |
-- A typeclass constraint
--
type Constraint = (Qualified (ProperName 'ClassName), [Type])

$(A.deriveJSON A.defaultOptions ''Type)

-- |
-- Convert a row to a list of pairs of labels and types
--
rowToList :: Type -> ([(String, Type)], Type)
rowToList (RCons name ty row) = let (tys, rest) = rowToList row
                                in ((name, ty):tys, rest)
rowToList r = ([], r)

-- |
-- Convert a list of labels and types to a row
--
rowFromList :: ([(String, Type)], Type) -> Type
rowFromList ([], r) = r
rowFromList ((name, t):ts, r) = RCons name t (rowFromList (ts, r))

-- |
-- Check whether a type is a monotype
--
isMonoType :: Type -> Bool
isMonoType ForAll{} = False
isMonoType _        = True

-- |
-- Universally quantify a type
--
mkForAll :: [String] -> Type -> Type
mkForAll args ty = foldl (\t arg -> ForAll arg t Nothing) ty args

-- |
-- Replace a type variable, taking into account variable shadowing
--
replaceTypeVars :: String -> Type -> Type -> Type
replaceTypeVars v r = replaceAllTypeVars [(v, r)]

-- |
-- Replace named type variables with types
--
replaceAllTypeVars :: [(String, Type)] -> Type -> Type
replaceAllTypeVars = go []
  where

  go :: [String] -> [(String, Type)] -> Type -> Type
  go _  m (TypeVar v) = fromMaybe (TypeVar v) (v `lookup` m)
  go bs m (TypeApp t1 t2) = TypeApp (go bs m t1) (go bs m t2)
  go bs m f@(ForAll v t sco) | v `elem` keys = go bs (filter ((/= v) . fst) m) f
                             | v `elem` usedVars =
                               let v' = genName v (keys ++ bs ++ usedVars)
                                   t' = go bs [(v, TypeVar v')] t
                               in ForAll v' (go (v' : bs) m t') sco
                             | otherwise = ForAll v (go (v : bs) m t) sco
    where
    keys = map fst m
    usedVars = concatMap (usedTypeVariables . snd) m
  go bs m (ConstrainedType cs t) = ConstrainedType (map (second $ map (go bs m)) cs) (go bs m t)
  go bs m (RCons name' t r) = RCons name' (go bs m t) (go bs m r)
  go bs m (KindedType t k) = KindedType (go bs m t) k
  go _  _ ty = ty

  genName orig inUse = try 0
    where
    try :: Integer -> String
    try n | (orig ++ show n) `elem` inUse = try (n + 1)
          | otherwise = orig ++ show n

-- |
-- Collect all type variables appearing in a type
--
usedTypeVariables :: Type -> [String]
usedTypeVariables = nub . everythingOnTypes (++) go
  where
  go (TypeVar v) = [v]
  go _ = []

-- |
-- Collect all free type variables appearing in a type
--
freeTypeVariables :: Type -> [String]
freeTypeVariables = nub . go []
  where
  go :: [String] -> Type -> [String]
  go bound (TypeVar v) | v `notElem` bound = [v]
  go bound (TypeApp t1 t2) = go bound t1 ++ go bound t2
  go bound (ForAll v t _) = go (v : bound) t
  go bound (ConstrainedType cs t) = concatMap (concatMap (go bound) . snd) cs ++ go bound t
  go bound (RCons _ t r) = go bound t ++ go bound r
  go bound (KindedType t _) = go bound t
  go _ _ = []

-- |
-- Universally quantify over all type variables appearing free in a type
--
quantify :: Type -> Type
quantify ty = foldr (\arg t -> ForAll arg t Nothing) ty $ freeTypeVariables ty

-- |
-- Move all universal quantifiers to the front of a type
--
moveQuantifiersToFront :: Type -> Type
moveQuantifiersToFront = go [] []
  where
  go qs cs (ForAll q ty sco) = go ((q, sco) : qs) cs ty
  go qs cs (ConstrainedType cs' ty) = go qs (cs ++ cs') ty
  go qs cs ty =
    let constrained = case cs of
                        [] -> ty
                        cs' -> ConstrainedType cs' ty
    in case qs of
         [] -> constrained
         qs' -> foldl (\ty' (q, sco) -> ForAll q ty' sco) constrained qs'

-- |
-- Check if a type contains wildcards
--
containsWildcards :: Type -> Bool
containsWildcards = everythingOnTypes (||) go
  where
  go :: Type -> Bool
  go TypeWildcard = True
  go _ = False

--
-- Traversals
--

everywhereOnTypes :: (Type -> Type) -> Type -> Type
everywhereOnTypes f = go
  where
  go (TypeApp t1 t2) = f (TypeApp (go t1) (go t2))
  go (ForAll arg ty sco) = f (ForAll arg (go ty) sco)
  go (ConstrainedType cs ty) = f (ConstrainedType (map (fmap (map go)) cs) (go ty))
  go (RCons name ty rest) = f (RCons name (go ty) (go rest))
  go (KindedType ty k) = f (KindedType (go ty) k)
  go (PrettyPrintFunction t1 t2) = f (PrettyPrintFunction (go t1) (go t2))
  go (PrettyPrintObject t) = f (PrettyPrintObject (go t))
  go (PrettyPrintForAll args t) = f (PrettyPrintForAll args (go t))
  go other = f other

everywhereOnTypesTopDown :: (Type -> Type) -> Type -> Type
everywhereOnTypesTopDown f = go . f
  where
  go (TypeApp t1 t2) = TypeApp (go (f t1)) (go (f t2))
  go (ForAll arg ty sco) = ForAll arg (go (f ty)) sco
  go (ConstrainedType cs ty) = ConstrainedType (map (fmap (map (go . f))) cs) (go (f ty))
  go (RCons name ty rest) = RCons name (go (f ty)) (go (f rest))
  go (KindedType ty k) = KindedType (go (f ty)) k
  go (PrettyPrintFunction t1 t2) = PrettyPrintFunction (go (f t1)) (go (f t2))
  go (PrettyPrintObject t) = PrettyPrintObject (go (f t))
  go (PrettyPrintForAll args t) = PrettyPrintForAll args (go (f t))
  go other = f other

everywhereOnTypesM :: Monad m => (Type -> m Type) -> Type -> m Type
everywhereOnTypesM f = go
  where
  go (TypeApp t1 t2) = (TypeApp <$> go t1 <*> go t2) >>= f
  go (ForAll arg ty sco) = (ForAll arg <$> go ty <*> pure sco) >>= f
  go (ConstrainedType cs ty) = (ConstrainedType <$> mapM (sndM (mapM go)) cs <*> go ty) >>= f
  go (RCons name ty rest) = (RCons name <$> go ty <*> go rest) >>= f
  go (KindedType ty k) = (KindedType <$> go ty <*> pure k) >>= f
  go (PrettyPrintFunction t1 t2) = (PrettyPrintFunction <$> go t1 <*> go t2) >>= f
  go (PrettyPrintObject t) = (PrettyPrintObject <$> go t) >>= f
  go (PrettyPrintForAll args t) = (PrettyPrintForAll args <$> go t) >>= f
  go other = f other

everywhereOnTypesTopDownM :: Monad m => (Type -> m Type) -> Type -> m Type
everywhereOnTypesTopDownM f = go <=< f
  where
  go (TypeApp t1 t2) = TypeApp <$> (f t1 >>= go) <*> (f t2 >>= go)
  go (ForAll arg ty sco) = ForAll arg <$> (f ty >>= go) <*> pure sco
  go (ConstrainedType cs ty) = ConstrainedType <$> mapM (sndM (mapM (go <=< f))) cs <*> (f ty >>= go)
  go (RCons name ty rest) = RCons name <$> (f ty >>= go) <*> (f rest >>= go)
  go (KindedType ty k) = KindedType <$> (f ty >>= go) <*> pure k
  go (PrettyPrintFunction t1 t2) = PrettyPrintFunction <$> (f t1 >>= go) <*> (f t2 >>= go)
  go (PrettyPrintObject t) = PrettyPrintObject <$> (f t >>= go)
  go (PrettyPrintForAll args t) = PrettyPrintForAll args <$> (f t >>= go)
  go other = f other

everythingOnTypes :: (r -> r -> r) -> (Type -> r) -> Type -> r
everythingOnTypes (<>) f = go
  where
  go t@(TypeApp t1 t2) = f t <> go t1 <> go t2
  go t@(ForAll _ ty _) = f t <> go ty
  go t@(ConstrainedType cs ty) = foldl (<>) (f t) (map go $ concatMap snd cs) <> go ty
  go t@(RCons _ ty rest) = f t <> go ty <> go rest
  go t@(KindedType ty _) = f t <> go ty
  go t@(PrettyPrintFunction t1 t2) = f t <> go t1 <> go t2
  go t@(PrettyPrintObject t1) = f t <> go t1
  go t@(PrettyPrintForAll _ t1) = f t <> go t1
  go other = f other

everythingWithContextOnTypes :: s -> r -> (r -> r -> r) -> (s -> Type -> (s, r)) -> Type -> r
everythingWithContextOnTypes s0 r0 (<>) f = go' s0
  where
  go' s t = let (s', r) = f s t in r <> go s' t
  go s (TypeApp t1 t2) = go' s t1 <> go' s t2
  go s (ForAll _ ty _) = go' s ty
  go s (ConstrainedType cs ty) = foldl (<>) r0 (map (go' s) $ concatMap snd cs) <> go' s ty
  go s (RCons _ ty rest) = go' s ty <> go' s rest
  go s (KindedType ty _) = go' s ty
  go s (PrettyPrintFunction t1 t2) = go' s t1 <> go' s t2
  go s (PrettyPrintObject t1) = go' s t1
  go s (PrettyPrintForAll _ t1) = go' s t1
  go _ _ = r0
