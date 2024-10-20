module Elara.Core.ToANF where

import Control.Monad.Cont
import Data.Traversable (for)
import Elara.AST.VarRef
import Elara.Core qualified as Core
import Elara.Core.ANF qualified as ANF
import Elara.Core.Analysis (exprType)
import Elara.Core.Generic (Bind (..))
import Elara.Data.Unique
import Polysemy

{- | Convert a Core expression to ANF
For example:
@let main = print (f (g (h 1)))@
becomes:
@ let main =
    let v1 = h 1 in
    let v2 = g v1 in
    let v3 = f v2 in
    print v3
@
-}

-- toANF :: Core.CoreExpr -> Sem r (ANF.Expr Core.Var)
-- toANF expr = (toANF' expr pure)

toANF :: Member UniqueGen r => Core.CoreExpr -> Sem r (ANF.Expr Core.Var)
toANF expr = toANF' expr (\e -> pure (ANF.CExpr $ ANF.AExpr e))

toANFCont :: Member UniqueGen r => Core.CoreExpr -> ContT (ANF.Expr Core.Var) (Sem r) (ANF.AExpr Core.Var)
toANFCont e = ContT $ \k -> toANF' e k

toANF' :: Member UniqueGen r => Core.CoreExpr -> (ANF.AExpr Core.Var -> Sem r (ANF.Expr Core.Var)) -> Sem r (ANF.Expr Core.Var)
toANF' (Core.Lit l) k = k $ ANF.Lit l
toANF' (Core.Var v) k = k $ ANF.Var v
toANF' (Core.TyApp v t) k = toANF' v $ \v' -> k $ ANF.TyApp v' t
toANF' (Core.TyLam t e) k = toANF' e $ \e' -> k $ ANF.TyLam t e'
toANF' (Core.Lam b e) k = toANFRec e $ \e' -> lift $ k $ ANF.Lam b (ANF.CExpr e')
toANF' other k = evalContT $ do
    v <- lift $ makeUnique "var"
    let id = Core.Id (Local' v) (exprType other) Nothing

    l' <- lift $ k $ ANF.Var id
    lift $ toANFRec other $ \e -> do
        pure $ ANF.Let (NonRecursive (id, e)) l'

toANFRec ::
    Member UniqueGen r =>
    Core.Expr Core.Var ->
    (ANF.CExpr Core.Var -> ContT (ANF.Expr Core.Var) (Sem r) (ANF.Expr Core.Var)) ->
    Sem r (ANF.Expr Core.Var)
toANFRec (Core.App f x) k = evalContT $ do
    f' <- toANFCont f
    x' <- toANFCont x
    k (ANF.App f' x')
toANFRec (Core.Match bind as cases) k = evalContT $ do
    bind <- toANFCont bind
    cases' <- for cases $ \(con, bs, e) -> do
        e' <- toANFCont e
        pure (con, bs, ANF.AExpr e')
    k $ ANF.Match bind as cases'
toANFRec other k = evalContT $ do
    y <- toANFCont other
    k $ ANF.AExpr y


fromANF :: ANF.Expr Core.Var -> Core.CoreExpr
fromANF (ANF.Let (NonRecursive (b, e)) body) = Core.Let (NonRecursive (b, fromANFCExpr e)) $ fromANF body
fromANF (ANF.Let (Recursive bs) body) = Core.Let (Recursive $ fromANFCExpr <<$>> bs) $ fromANF body
fromANF (ANF.CExpr e) = fromANFCExpr e

fromANFCExpr :: ANF.CExpr Core.Var -> Core.CoreExpr
fromANFCExpr (ANF.App f x) = Core.App (fromANFAtom f) (fromANFAtom x)
fromANFCExpr (ANF.Match e b alts) = Core.Match (fromANFAtom e) b $ fmap (\(con, bs, e) -> (con, bs, fromANFCExpr e)) alts
fromANFCExpr (ANF.AExpr e) = fromANFAtom e

fromANFAtom :: ANF.AExpr Core.Var -> Core.Expr Core.Var
fromANFAtom (ANF.Lit i) = Core.Lit i
fromANFAtom (ANF.Var v) = Core.Var v
fromANFAtom (ANF.Lam b e) = Core.Lam b $ fromANF e
fromANFAtom (ANF.TyLam l e) = Core.TyLam l $ fromANFAtom e
fromANFAtom (ANF.TyApp e t) = Core.TyApp (fromANFAtom e) t
