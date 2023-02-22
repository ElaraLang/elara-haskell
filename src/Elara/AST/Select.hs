{-# LANGUAGE AllowAmbiguousTypes #-}
module Elara.AST.Select where

import Elara.AST.Annotated qualified as Annotated
import Elara.AST.Frontend qualified as Frontend
import Elara.AST.Frontend.Unlocated qualified as Frontend.Unlocated
import Elara.AST.Name (MaybeQualified, Qualified)
import Elara.AST.Region (Located (Located))
data Frontend

data UnlocatedFrontend

data Annotated

type family ASTExpr ast where
    ASTExpr Frontend = Frontend.Expr
    ASTExpr UnlocatedFrontend = Frontend.Unlocated.Expr
    ASTExpr Annotated = Annotated.Expr

type family ASTPattern ast where
    ASTPattern Frontend = Frontend.Pattern
    ASTPattern UnlocatedFrontend = Frontend.Pattern
    ASTPattern Annotated = Annotated.Pattern

type family ASTAnnotation ast where
    ASTAnnotation Frontend = Maybe Frontend.TypeAnnotation
    ASTAnnotation UnlocatedFrontend = Maybe Frontend.TypeAnnotation
    ASTAnnotation Annotated = Maybe Annotated.TypeAnnotation

type family ASTQual ast where
    ASTQual Frontend = MaybeQualified
    ASTQual UnlocatedFrontend = MaybeQualified
    ASTQual Annotated = Qualified

type family ASTLocate' ast where
    ASTLocate' Frontend = Located
    ASTLocate' UnlocatedFrontend = Unlocated
    ASTLocate' Annotated = Located

type ASTLocate ast a = UnwrapUnlocated (ASTLocate' ast a)

newtype Unlocated a = Unlocated a

type family UnwrapUnlocated g where
    UnwrapUnlocated (Unlocated a) = a
    UnwrapUnlocated a = a


type FullASTQual ast a = UnwrapUnlocated ((ASTLocate ast) (ASTQual ast a))



-- rUnlocate Located (MaybeQualified a) = MaybeQualified a 
-- fmapRUnlocate :: (a -> b) -> Located (MaybeQualified a) -> Located (MaybeQualified b)
-- rUnlocate MaybeQualified a = MaybeQualified b
-- fmapRUnlocate :: (a -> b) -> MaybeQualified a -> MaybeQualified b



type family Unlocate g where
    Unlocate (Located a) = a
    Unlocate a = a

class RUnlocate ast where
    rUnlocate :: FullASTQual ast a -> ASTQual ast a
    rUnlocate' :: ASTLocate ast a -> a
    fmapRUnlocate :: (a -> b) -> FullASTQual ast a -> FullASTQual ast b


instance RUnlocate Frontend where
    rUnlocate (Located _ a) = a
    rUnlocate' (Located _ a) = a
    fmapRUnlocate f (Located r a) = Located r (fmap f a)

instance RUnlocate UnlocatedFrontend where
    rUnlocate a = a
    rUnlocate' a = a
    fmapRUnlocate = fmap
