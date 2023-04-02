-- | Generates as many type unifications as possible from a given expression
module Elara.TypeInfer.GenerateEquations where

import Control.Lens
import Elara.AST.Name (ModuleName (ModuleName), Qualified (..), TypeName (TypeName), VarName)
import Elara.AST.Region (Located (Located), generatedSourceRegion, unlocated)
import Elara.AST.Typed
import Elara.Data.Pretty
import Elara.Data.Unique (Unique, UniqueGen, UniqueId, makeUniqueId)
import Elara.TypeInfer.Environment (TypeEnvironment, addToEnv)
import Polysemy
import Polysemy.State
import Polysemy.Writer (Writer, listen, tell)
import Print (debugColored)
import Prelude hiding (universe)

newtype TypeEquation = TypeEquation (PartialType, PartialType)
    deriving (Show, Eq, Ord)

(=:=) :: PartialType -> PartialType -> TypeEquation
(=:=) = curry TypeEquation

instance Pretty TypeEquation where
    pretty (TypeEquation (a, b)) = pretty a <+> "=:=" <+> pretty b

-- | Standard types
preludeName :: ModuleName
preludeName = ModuleName ("Prelude" :| [])

intType :: PartialType
intType = Final $ Type (UserDefinedType (Located (generatedSourceRegion Nothing) (Qualified (TypeName "Int") preludeName)))

floatType :: PartialType
floatType = Final $ Type (UserDefinedType (Located (generatedSourceRegion Nothing) (Qualified (TypeName "Float") preludeName)))

charType :: PartialType
charType = Final $ Type (UserDefinedType (Located (generatedSourceRegion Nothing) (Qualified (TypeName "Char") preludeName)))

stringType :: PartialType
stringType = Final $ Type (UserDefinedType (Located (generatedSourceRegion Nothing) (Qualified (TypeName "String") preludeName)))

unitType :: PartialType
unitType = Final $ Type (UserDefinedType (Located (generatedSourceRegion Nothing) (Qualified (TypeName "Unit") preludeName)))

generateEquations :: forall r. (Member (Writer (Set TypeEquation)) r, Member (State TypeEnvironment) r, Member UniqueGen r) => Expr PartialType -> Sem r ()
generateEquations = traverseOf_ (_Expr . unlocateFirst) generateEquations'
  where
    generateEquations' :: (Expr' PartialType, PartialType) -> Sem r ()
    generateEquations' (Int _, t) =
        tell $ one $ t =:= intType
    generateEquations' (Float _, t) =
        tell $ one $ t =:= floatType
    generateEquations' (Char _, t) =
        tell $ one $ t =:= charType
    generateEquations' (String _, t) =
        tell $ one $ t =:= stringType
    generateEquations' (Unit, t) = tell $ one $ t =:= unitType
    generateEquations' (Var vn, t) =
        whenJust (preview (unlocated . _Global) vn) $
            \vn' -> modify (addToEnv (Global vn') t)
    generateEquations' (Constructor _, _) = pass
    generateEquations' (Lambda arg body@(Expr (_, bodyType)), t) =
        do
            argType <- Id <$> makeUniqueId
            generateEquations body
            let usages = findUsagesOf (arg ^. unlocated) body
            generateArgumentUsageEquations argType usages

            let functionType = Partial (FunctionType argType bodyType) -- typeof (\a -> b) is typeof(a) -> typeof(b)
            tell $ one $ t =:= functionType
    generateEquations' (Match expr@(Expr (_, testType)) cases, overallType) = do
        generateEquations expr
        for_ cases $ \(pat@(Pattern (_, patType)), body@(Expr (_, bodyType))) -> do
            generatePatternEquations overallType pat
            tell $ one $ testType =:= patType
            generateEquations body
            tell $ one $ overallType =:= bodyType
    generateEquations' other = error ("Not sure how to generate equations for this expression yet: " <> show other)

findUsagesOf :: Unique VarName -> Expr PartialType -> [Expr PartialType]
findUsagesOf v e = e ^.. cosmos . filtered (view (_Expr . _1 . unlocated . to isVar))
  where
    isVar :: Expr' PartialType -> Bool
    isVar expr = preview (_Var . unlocated . _Local . unlocated) expr == Just v

generateArgumentUsageEquations :: forall r. (Member (Writer (Set TypeEquation)) r) => PartialType -> [Expr PartialType] -> Sem r ()
generateArgumentUsageEquations argId = traverseOf_ (each . _Expr . _2) generateArgumentUsageEquation
  where
    generateArgumentUsageEquation :: PartialType -> Sem r ()
    generateArgumentUsageEquation t = tell $ one $ argId =:= t

generatePatternEquations ::
    forall r.
    ( Member (Writer (Set TypeEquation)) r
    ) =>
    PartialType ->
    Pattern PartialType ->
    Sem r ()
generatePatternEquations ty = traverseOf_ (_Pattern . unlocateFirst) generatePatternEquations'
  where
    generatePatternEquations' :: (Pattern' PartialType, PartialType) -> Sem r ()
    generatePatternEquations' (WildcardPattern, _) = pass
    -- While the literal patterns infer a certain type for the
    generatePatternEquations' (IntegerPattern _, _) =
        tell $ one $ ty =:= intType
    generatePatternEquations' (FloatPattern _, _) =
        tell $ one $ ty =:= floatType
    generatePatternEquations' (CharPattern _, _) =
        tell $ one $ ty =:= charType
    generatePatternEquations' (StringPattern _, _) =
        tell $ one $ ty =:= stringType
    generatePatternEquations' (VarPattern _, _) = pass -- doesn't tell us anything
    generatePatternEquations' _ = error "Not sure how to generate pattern equations for this pattern yet"

-- I cannot figure out how to write this lens the "right" way. sorry
unlocateFirst :: Lens (Located a1, b1) (Located b2, b1) (a1, b1) (b2, b)
unlocateFirst = lens getter setter
  where
    getter (a, b) = (view unlocated a, b)
    setter (l, b) (a, _) = (set unlocated a l, b)
