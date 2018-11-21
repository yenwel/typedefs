module Backend.Haskell

import Data.Vect
import Control.Monad.State
import Text.PrettyPrint.WL

import Backend.Utils
import Types
import Typedefs

%default partial
%access public export

{-
TODO
 Remove TDef -> String funs
 Rename funs
 Move and rename SynEnv
-}


data HaskellType : Type where
  T0 : HaskellType
  T1 : HaskellType
  TSum : Vect (2 + k) HaskellType -> HaskellType
  TProd : Vect (2 + k) HaskellType -> HaskellType
  TVar : Name -> HaskellType
  TCons : Name -> List HaskellType -> HaskellType 

isSimple : HaskellType -> Bool
isSimple (TSum _)    = False
isSimple (TCons _ ts) = isNil ts
isSimple _           = True

data HaskellDef : Type where
  Synonym : (name : Name) -> (vars : Vect n Name) -> HaskellType -> HaskellDef
  ADT     : (name : Name) -> (vars : Vect n Name) -> Vect k (Name, HaskellType) -> HaskellDef

makeDoc : HaskellType -> Doc
makeDoc T0 = text "Void"
makeDoc T1 = text "()"
makeDoc (TSum xs) = tsum xs
  where
  tsum : Vect (2 + _) HaskellType -> Doc
  tsum [x, y]              = text "Either" |++| (if isSimple x then makeDoc x else parens (makeDoc x)) |++| (if isSimple y then makeDoc y else parens (makeDoc y))
  tsum (x :: y :: z :: zs) = text "Either" |++| (if isSimple x then makeDoc x else parens (makeDoc x)) |++| parens (tsum (y :: z :: zs))
makeDoc (TProd xs)      = tupled . toList $ map makeDoc xs
makeDoc (TVar v)        = text v
makeDoc (TCons name ts) = text name |+| hsep (empty::(map guardParen ts))
  where
  guardParen : HaskellType -> Doc
  guardParen ht = if isSimple ht then makeDoc ht else text ">" |++| parens (makeDoc ht) |++| text "<" -- Can this ever be false?

docifyCase : (Name, HaskellType) -> Doc
docifyCase (n, T1) = text n
docifyCase (n, TProd ts) = text n |++| hsep (toList (map (\t => if isSimple t then makeDoc t else parens (makeDoc t)) ts))
docifyCase (n, ht) = text n |++| makeDoc ht

docify : HaskellDef -> Doc
docify (Synonym name vars body) = text "type" |++| text name |+| hsep (empty :: toList (map text vars)) |++| equals |++| makeDoc body
docify (ADT name vars cases) = text "data" |++| text name |+| hsep (empty :: toList (map text vars)) |++| equals |++| hsep (punctuate (text " |") (toList $ map docifyCase cases))

--guardPar : String -> String
--guardPar str = if any isSpace $ unpack str then parens str else str

--nameWithParams : Name -> Env n -> String
--nameWithParams name e = withSep " " id (uppercase name::map lowercase (getFreeVars e))

SynEnv : Nat -> Type
SynEnv n = Vect n (Either Name (Name, List HaskellType))

freshSynEnv : (n: Nat) -> SynEnv n
freshSynEnv n = unindex {n} (\f => Left ("x" ++ show (finToInteger f)))

getFreeVars : (e : SynEnv n) -> Vect (fst (Vect.filter Either.isLeft e)) String
getFreeVars e with (filter isLeft e) 
  | (p ** v) = map (either id (const "")) v

makeSynType : SynEnv n -> TDef n -> HaskellType
makeSynType     _ T0             = T0
makeSynType     _ T1             = T1
makeSynType {n} e (TSum xs)      = TSum $ map (makeSynType e) xs
makeSynType     e (TProd xs)     = TProd $ map (makeSynType e) xs
makeSynType     e (TVar v)       = either TVar (uncurry TCons) $ Vect.index v e
makeSynType     e (TMu name _)   = TCons name (toList $ map TVar $ getFreeVars e)
makeSynType     e (TName name _) = TCons name (toList $ map TVar $ getFreeVars e)

-- makeType : Env n -> TDef n -> Doc
-- makeType     _ T0             = text "Void"
-- makeType     _ T1             = text "()"
-- makeType {n} e (TSum xs)      = tsum xs
--   where
--   tsum : Vect (2 + _) (TDef n) -> Doc
--   tsum [x, y]              = text "Either" |++| parens (makeType e x) |++| parens (makeType e y)
--   tsum (x :: y :: z :: zs) = text "Either" |++| parens (makeType e x) |++| parens (tsum (y :: z :: zs))
-- makeType     e (TProd xs)     = tupled . toList $ map (makeType e) xs
-- makeType     e (TVar v)       = text $ either id id $ Vect.index v e
-- makeType     e (TMu name _)   = text $ nameWithParams name e
-- makeType     e (TName name _) = text $ nameWithParams name e

makeDefs : SynEnv n -> TDef n -> State (List Name) (List HaskellDef)
makeDefs _ T0            = pure []
makeDefs _ T1            = pure []
makeDefs e (TProd xs)    = map concat $ traverse (makeDefs e) (toList xs)
makeDefs e (TSum xs)     = map concat $ traverse (makeDefs e) (toList xs)
makeDefs _ (TVar v)      = pure []
makeDefs e (TMu name cs) = 
   do st <- get 
      if List.elem name st then pure [] 
       else let
          newEnv = Right (name, map TVar $ toList $ getFreeVars e) :: e
          args = map (map (makeSynType newEnv)) cs
         in
        do res <- map concat $ traverse {b=List HaskellDef} (\(_, bdy) => makeDefs newEnv bdy) (toList cs) 
           put (name :: st)
           pure $ ADT name (getFreeVars e) args :: res -- (text "data" |++| text dataName |++| equals |++| args) :: res
--  where
--  mkArg : Env (S n) -> (Name, TDef (S n)) -> (Name, HaskellType)
--  mkArg _ (cname, T1)       = (cname, T1)
--  mkArg e (cname, TProd xs) = text cname |++| (hsep . toList) (map (makeType e) xs)
--  mkArg e (cname, ctype)    = text cname |++| makeType e ctype
makeDefs e (TName name body) = 
  do st <- get 
     if List.elem name st then pure []
       else 
        do res <- makeDefs e body 
           put (name :: st)
           pure $ Synonym name (getFreeVars e) (makeSynType e body) :: res -- (text "type" |++| text (nameWithParams name e) |++| equals |++| makeType e body) :: res

-- generate type body, only useful for anonymous tdefs (i.e. without wrapping Mu/Name)
-- generateType : TDef n -> Doc
-- generateType {n} = makeType (freshEnv n)

-- generate data definitions
generate : TDef n -> Doc
generate {n} td = vsep2 . map docify . reverse $ evalState (makeDefs (freshSynEnv n) td) []