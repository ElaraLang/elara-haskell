{-# LANGUAGE RecordWildCards #-}

module Elara.Desugar.Desugar where

import Control.Lens (set, view, (^.))
import Data.Map qualified as M
import Data.Text (pack)
import Elara.AST.Canonical qualified as Canonical
import Elara.AST.Frontend qualified as Frontend
import Elara.Data.Located (IsLocated, Located (..))
import Elara.Data.Module
import Elara.Data.Module.Inspection
import Elara.Data.Name (ModuleName, QualifiedName (QualifiedName))
import Elara.Data.Project (Project (..))
import Elara.Data.Qualifications (MaybeQualified, Qualified)
import Elara.Data.Type
import Elara.Data.TypeAnnotation (TypeAnnotation (..))
import Elara.Error (DesugarError (CantDesugar))
import Relude
import Utils qualified

type DesugarResult = Either DesugarError

type SourceModule = Module Frontend.LocatedExpr Frontend.Pattern TypeAnnotation MaybeQualified

type CanonicalModule = Module Canonical.LocatedExpr Canonical.Pattern (ConcreteType Qualified) Qualified

type SourceDeclaration = Declaration Frontend.LocatedExpr Frontend.Pattern TypeAnnotation MaybeQualified

type CanonicalDeclaration = Declaration Canonical.LocatedExpr Canonical.Pattern (ConcreteType Qualified) Qualified

desugarProject :: Project Frontend.ProjectFields -> DesugarResult (Project Canonical.ProjectFields)
desugarProject project@Project {..} = do
  let allModules = fields.modules
  modules' <- traverse (desugarModule allModules) (M.elems allModules)
  let newFields = Canonical.ProjectFields (Utils.associateWithKey (view name) modules')
  return project {fields = newFields}

desugarModule :: M.Map ModuleName SourceModule -> SourceModule -> DesugarResult CanonicalModule
desugarModule modules module'@Module {..} = do
  declarations' <- traverse (desugarDeclaration modules module') (module' ^. declarations)
  return module' {_moduleDeclarations = declarations'}

desugarDeclaration :: M.Map ModuleName SourceModule -> SourceModule -> SourceDeclaration -> DesugarResult CanonicalDeclaration
desugarDeclaration modules thisModule dec@Declaration {..} = do
  case view body dec of
    ValueTypeDef annotation -> Declaration _declarationModule_ _declarationName . ValueTypeDef <$> desugarAnnotation annotation
    Value expr patterns ty -> do
      expr' <- desugarExpr modules thisModule expr
      patterns' <- traverse desugarPattern patterns
      ty' <- traverse desugarAnnotation ty

      return $ Declaration _declarationModule_ _declarationName $ Value expr' patterns' ty'
    _ -> Left . CantDesugar $ "desugarDeclaration: " <> show dec

desugarExpr :: M.Map ModuleName SourceModule -> SourceModule -> Frontend.LocatedExpr -> DesugarResult Canonical.LocatedExpr
desugarExpr modules thisModule (Located _ (Frontend.Lambda args body)) = do
  -- turns \x y z -> ... into \x -> \y -> \z -> ...
  args' <- traverse desugarPattern args
  body' <- desugarExpr modules thisModule body
  let curryLambda = foldr (\arg body'' -> Canonical.Lambda arg body'' <$ body) body' args'
  return curryLambda
desugarExpr modules thisModule e = traverse desugarExpr' e
  where
    desugarExpr' :: Frontend.Expr IsLocated -> DesugarResult Canonical.Expr
    desugarExpr' expr = case expr of
      Frontend.Int i -> return $ Canonical.Int i
      Frontend.Float f -> return $ Canonical.Float f
      Frontend.String s -> return $ Canonical.String s
      Frontend.Bool b -> return $ Canonical.Bool b
      Frontend.Unit -> return Canonical.Unit
      Frontend.Argument name -> return $ Canonical.Argument name
      Frontend.Var name -> do
        x <- findModuleOfVar modules thisModule name
        return (Canonical.Var (QualifiedName x name))
      Frontend.BinaryOperator op left right -> do
        op' <- desugarExpr modules thisModule op
        left' <- desugarExpr modules thisModule left
        right' <- desugarExpr modules thisModule right
        return $ Canonical.BinaryOperator op' left' right'
      Frontend.FunctionCall f arg -> do
        f' <- desugarExpr modules thisModule f
        arg' <- desugarExpr modules thisModule arg
        return $ Canonical.FunctionCall f' arg'
      Frontend.If cond then_ else_ -> do
        cond' <- desugarExpr modules thisModule cond
        then_' <- desugarExpr modules thisModule then_
        else_' <- desugarExpr modules thisModule else_
        return $ Canonical.If cond' then_' else_'
      Frontend.Block exprs -> do
        exprs' <- traverse (desugarExpr modules thisModule) exprs
        return $ Canonical.Block exprs'
      other -> Left . CantDesugar $ "desugarExpr: " <> show other

desugarPattern :: Frontend.Pattern -> DesugarResult Canonical.Pattern
desugarPattern pat = case pat of
  Frontend.WildPattern -> return Canonical.WildPattern
  Frontend.NamedPattern name -> return $ Canonical.NamedPattern name

desugarAnnotation :: TypeAnnotation -> DesugarResult (ConcreteType Qualified)
desugarAnnotation TypeAnnotation {..} = desugarType _type

desugarType :: ConcreteType MaybeQualified -> DesugarResult (ConcreteType Qualified)
desugarType (Concrete t q) = flip Concrete (fromMaybe (error $ "cannot resolve " <> show newType) q) <$> newType
  where
    newType = case t of
      (TypeVar n) -> return (TypeVar n)
      Function from to -> do
        from' <- desugarType from
        to' <- desugarType to
        return (Function from' to')
      Int -> return Int
      Float -> return Float
      Bool -> return Bool
      String -> return String
      Unit -> return Unit
      _ -> Left . CantDesugar $ "desugarType: " <> show t