module TypeInferrer.Expr where

import Control.Monad.Except
import Control.Monad.RWS (listen)
import Control.Monad.State
import qualified Interpreter.AST as A
import TypeInferrer.Env

inferExpression :: A.Expression -> Infer Type
inferExpression ex = case ex of
  A.Constant (A.IntC _) -> return $ TCon "Int"
  A.Constant A.UnitC -> return $ TCon "()"
  A.List [] -> TConApp (TCon "List") <$> fresh
  -- [a]

  A.Reference x -> lookupEnv (show x)
  A.Lambda param body -> do
    tv <- fresh
    t <- inEnv (show param, Forall [] tv) (inferExpression body)
    return (tv `TFunc` t)
  A.BindWithBody name val body -> do
    env <- gets typeEnv
    (t0, constraints) <- listen $ inferExpression val
    subst <- liftEither $ runSolve constraints
    let t1 = apply subst t0
    let sc = generalize env t1
    inEnv (show name, sc) $ inferExpression body
  A.BindGlobal name val -> do
    i <- inferExpression (A.BindWithBody name val (A.Reference name))
    env <- gets typeEnv
    let sc = generalize env i
    addToEnv (show name, sc)
    return (TCon "()")
  A.FunctionApplication f arg -> do
    t1 <- inferExpression f
    t2 <- inferExpression arg
    tv <- fresh
    uni t1 (t2 `TFunc` tv)
    return tv
  A.Block exprs -> do
    xs <- mapM inferExpression exprs
    return $ last xs
  other -> throwError $ Other $ "Cannot infer type of expression: " ++ show other
