{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

{- | A `Context` is an ordered list of `Entry`s used as the state for the
   bidirectional type-checking algorithm
-}
module Elara.TypeInfer.Context (
    -- * Types
    Entry (..),
    Context,

    -- * Utilities
    lookup,
    discardUpToExcluding,
    splitOnUnsolvedType,
    splitOnUnsolvedFields,
    splitOnUnsolvedAlternatives,
    discardUpTo,
    solveType,
    solveRecord,
    complete,
    ContextGraph (..),
    simplifyContext,
    unifyContextGraph,
    solveFromGraph,
    graphToContext,
)
where

import Algebra.Graph qualified as Algebraic.Graph
import Algebra.Graph.Export.Dot (defaultStyle, defaultStyleViaShow, export, exportAsIs, exportViaShow)
import Algebra.Graph.ToGraph (reachable)
import Algebra.Graph.Undirected hiding (Context)
import Control.Monad qualified as Monad
import Data.Generics.Sum (AsAny (_As))
import Data.List (groupBy)
import Data.List.NonEmpty (groupAllWith)
import Data.List.NonEmpty qualified as NE
import Elara.AST.Name (Name)
import Elara.AST.StripLocation (StripLocation (..))
import Elara.AST.VarRef (IgnoreLocVarRef)
import Elara.Data.Pretty (AnsiStyle, Doc, Pretty (..), prettyToUnannotatedText)
import Elara.Data.Pretty.Styles (label, operator, punctuation)
import Elara.Data.Unique (UniqueGen)
import Elara.Logging (StructuredDebug, debug, debugWith)
import Elara.TypeInfer.Domain (Domain)
import Elara.TypeInfer.Domain qualified as Domain
import Elara.TypeInfer.Existential (Existential)
import Elara.TypeInfer.Monotype (Monotype)
import Elara.TypeInfer.Monotype qualified as Monotype
import Elara.TypeInfer.Type (Type)
import Elara.TypeInfer.Type qualified as Type
import Elara.TypeInfer.Unique
import Optics (hasn't)
import Polysemy
import Polysemy.State
import Prettyprinter qualified as Pretty
import Print (debugPretty, showPretty)
import Prelude hiding (empty)

{- $setup

  >>> :set -XOverloadedStrings
  >>> :set -XTypeApplications
  >>> :set -Wno-deprecations
  >>> import Elara.TypeInfer.Type (Record, Union)
  >>> import Elara.TypeInfer.Type qualified as Type
  >>> import Elara.TypeInfer.Monotype qualified as Monotype
  >>> import Elara.TypeInfer.Type (Type)
  >>> import Elara.Data.Pretty (Pretty (..), Doc, AnsiStyle)
  >>> import Elara.Data.Pretty.Styles (label, operator, punctuation)
  >>> import Elara.TypeInfer.Domain qualified as Domain
  >>> import Elara.AST.VarRef
  >>> import Elara.AST.Region
  >>> import Elara.AST.Name
  >>> import Elara.Data.Unique
  >>> import Relude (undefined)
-}

-- | An element of the `Context` list
data Entry s
    = -- | Universally quantified variable
      --
      -- >>> pretty @(Entry ()) (Variable Domain.Type "a")
      -- a: Type
      Variable Domain UniqueTyVar
    | -- | A bound variable whose type is known
      --
      -- >>>  pretty @(Entry ()) (Annotation (Local (IgnoreLocation (Located undefined (unsafeMkUnique (NVarName "x") 0)))) "a")
      -- x_0: a
      Annotation (IgnoreLocVarRef Name) (Type s)
    | -- | A placeholder type variable whose type has not yet been inferred
      --
      -- >>> pretty @(Entry ()) (UnsolvedType 0)
      -- a?
      UnsolvedType (Existential Monotype)
    | -- | A placeholder fields variable whose type has not yet been inferred
      --
      -- >>> pretty @(Entry ()) (UnsolvedFields 0)
      -- a?
      UnsolvedFields (Existential Monotype.Record)
    | -- | A placeholder alternatives variable whose type has not yet been
      -- inferred
      --
      -- >>> pretty @(Entry ()) (UnsolvedAlternatives 0)
      -- a?
      UnsolvedAlternatives (Existential Monotype.Union)
    | -- | A placeholder type variable whose type has been (at least partially)
      --   inferred
      --
      -- >>> pretty @(Entry ()) (SolvedType 0 (Monotype.Scalar Monotype.Bool))
      -- a = Bool
      SolvedType (Existential Monotype) Monotype
    | -- | A placeholder fields variable whose type has been (at least partially)
      --   inferred
      --
      -- >>> pretty @(Entry ()) (SolvedFields 0 (Monotype.Fields [("x", "X")] (Monotype.UnsolvedFields 1)))
      -- a = x: X, b?
      SolvedFields (Existential Monotype.Record) Monotype.Record
    | -- | A placeholder alternatives variable whose type has been (at least
      --   partially) inferred
      --
      -- >>> pretty @(Entry ()) (SolvedAlternatives 0 (Monotype.Alternatives [("x", "X")] (Monotype.UnsolvedAlternatives 1)))
      -- a = x: X | b?
      SolvedAlternatives (Existential Monotype.Union) Monotype.Union
    | -- | This is used by the bidirectional type-checking algorithm to separate
      --   context entries introduced before and after type-checking a universally
      --   quantified type
      --
      -- >>> pretty @(Entry ()) (MarkerType 0)
      -- ➤ a: Type
      MarkerType (Existential Monotype)
    | -- | This is used by the bidirectional type-checking algorithm to separate
      --   context entries introduced before and after type-checking universally
      --   quantified fields
      --
      -- >>> pretty @(Entry ()) (MarkerFields 0)
      -- ➤ a: Fields
      MarkerFields (Existential Monotype.Record)
    | -- | This is used by the bidirectional type-checking algorithm to separate
      --   context entries introduced before and after type-checking universally
      --   quantified alternatives
      --
      -- >>> pretty @(Entry ()) (MarkerAlternatives 0)
      -- ➤ a: Alternatives
      MarkerAlternatives (Existential Monotype.Union)
    deriving stock (Eq, Show, Ord, Generic)

instance StripLocation (Entry s) (Entry ()) where
    stripLocation (Annotation x a) = Annotation x (stripLocation a)
    stripLocation (Variable domain a) = Variable domain a
    stripLocation (UnsolvedType a) = UnsolvedType a
    stripLocation (UnsolvedFields a) = UnsolvedFields a
    stripLocation (UnsolvedAlternatives a) = UnsolvedAlternatives a
    stripLocation (SolvedType a τ) = SolvedType a τ
    stripLocation (SolvedFields a r) = SolvedFields a r
    stripLocation (SolvedAlternatives a r) = SolvedAlternatives a r
    stripLocation (MarkerType a) = MarkerType a
    stripLocation (MarkerFields a) = MarkerFields a
    stripLocation (MarkerAlternatives a) = MarkerAlternatives a

instance Show s => Pretty (Entry s) where
    pretty = prettyEntry

{- | A `Context` is an ordered list of `Entry`s

   Note that this representation stores the `Context` entries in reverse
   order, meaning that the beginning of the list represents the entries that
   were added last.  For example, this context:

   > •, a : Bool, b, c?, d = c?, ➤e : Type

   … corresponds to this Haskell representation:

   > [ MarkerType 4
   > , SolvedType 3 (Monotype.UnsolvedType 2)
   > , UnsolvedType 2
   > , Variable "b"
   > , Annotation "a" (Monotype.Scalar Monotype.Bool)
   > ]

   The ordering matters because the bidirectional type-checking algorithm
   uses ordering of `Context` entries to determine scope.  Specifically:

   * each `Entry` in the `Context` can only refer to variables preceding it
     within the `Context`

   * the bidirectional type-checking algorithm sometimes discards all entries
     in the context past a certain entry to reflect the end of their
     \"lifetime\"
-}
type Context s = [Entry s]

prettyEntry :: Show s => Entry s -> Doc AnsiStyle
prettyEntry (Variable domain a) =
    label (pretty a) <> operator ":" <> " " <> pretty domain
prettyEntry (UnsolvedType a) =
    pretty a <> "?"
prettyEntry (UnsolvedFields p) =
    pretty p <> "?"
prettyEntry (UnsolvedAlternatives p) =
    pretty p <> "?"
prettyEntry (SolvedType a τ) =
    pretty a <> " " <> punctuation "=" <> " " <> pretty τ
prettyEntry (SolvedFields p (Monotype.Fields [] Monotype.EmptyFields)) =
    pretty p <> " " <> punctuation "=" <> " " <> punctuation "•"
prettyEntry (SolvedFields p0 (Monotype.Fields [] (Monotype.UnsolvedFields p1))) =
    pretty p0
        <> " "
        <> punctuation "="
        <> " "
        <> pretty p1
        <> "?"
prettyEntry (SolvedFields p0 (Monotype.Fields [] (Monotype.VariableFields p1))) =
    pretty p0
        <> " "
        <> punctuation "="
        <> " "
        <> label (pretty p1)
prettyEntry (SolvedFields p (Monotype.Fields ((k0, τ0) : kτs) fields)) =
    pretty p
        <> " = "
        <> label (pretty k0)
        <> operator ":"
        <> " "
        <> pretty τ0
        <> foldMap prettyFieldType kτs
        <> case fields of
            Monotype.EmptyFields ->
                ""
            Monotype.UnsolvedFields p1 ->
                punctuation "," <> " " <> pretty p1 <> "?"
            Monotype.VariableFields p1 ->
                punctuation "," <> " " <> pretty p1
prettyEntry (SolvedAlternatives p (Monotype.Alternatives [] Monotype.EmptyAlternatives)) =
    pretty p <> " " <> punctuation "=" <> " " <> punctuation "•"
prettyEntry (SolvedAlternatives p0 (Monotype.Alternatives [] (Monotype.UnsolvedAlternatives p1))) =
    pretty p0 <> " " <> punctuation "=" <> " " <> pretty p1 <> "?"
prettyEntry (SolvedAlternatives p0 (Monotype.Alternatives [] (Monotype.VariableAlternatives p1))) =
    pretty p0 <> " " <> punctuation "=" <> " " <> label (pretty p1)
prettyEntry (SolvedAlternatives p0 (Monotype.Alternatives ((k0, τ0) : kτs) fields)) =
    pretty p0
        <> " "
        <> punctuation "="
        <> " "
        <> prettyAlternativeType (k0, τ0)
        <> foldMap (\kt -> " " <> punctuation "|" <> " " <> prettyAlternativeType kt) kτs
        <> case fields of
            Monotype.EmptyAlternatives ->
                ""
            Monotype.UnsolvedAlternatives p1 ->
                " " <> punctuation "|" <> " " <> pretty p1 <> "?"
            Monotype.VariableAlternatives p1 ->
                " " <> punctuation "|" <> " " <> label (pretty p1)
prettyEntry (Annotation x a) = Pretty.group (Pretty.flatAlt long short)
  where
    long =
        Pretty.align
            ( pretty x
                <> operator ":"
                <> Pretty.hardline
                <> "  "
                <> pretty a
            )

    short = pretty x <> operator ":" <> " " <> pretty a
prettyEntry (MarkerType a) =
    "➤ " <> pretty a <> ": Type"
prettyEntry (MarkerFields a) =
    "➤ " <> pretty a <> ": Fields"
prettyEntry (MarkerAlternatives a) =
    "➤ " <> pretty a <> ": Alternatives"

prettyFieldType :: (UniqueTyVar, Monotype) -> Doc AnsiStyle
prettyFieldType (k, τ) =
    punctuation "," <> " " <> pretty k <> operator ":" <> " " <> pretty τ

prettyAlternativeType :: (UniqueTyVar, Monotype) -> Doc AnsiStyle
prettyAlternativeType (k, τ) =
    pretty k <> operator ":" <> " " <> pretty τ

-- | Substitute a `Type` using the solved entries of a `Context`
solveType :: Context s -> Type s -> Type s
solveType context type_ = foldl' snoc type_ context
  where
    snoc t (SolvedType a τ) = Type.solveType a τ t
    snoc t (SolvedFields a r) = Type.solveFields a r t
    snoc t _ = t

-- | Substitute a t`Type.Record` using the solved entries of a `Context`
solveRecord :: Context s -> Type.Record s -> Type.Record s
solveRecord context oldFields = newFields
  where
    location =
        error "Grace.Context.solveRecord: Internal error - Missing location field"

    -- TODO: Come up with total solution
    Type.Record{fields = newFields} =
        solveType context Type.Record{fields = oldFields, ..}

{- | This function is used at the end of the bidirectional type-checking
   algorithm to complete the inferred type by:

   * Substituting the type with the solved entries in the `Context`

   * Adding universal quantifiers for all unsolved entries in the `Context`
-}
complete :: Member UniqueGen r => Context s -> Type s -> Sem r (Type s)
complete context type0 = Monad.foldM snoc type0 context
  where
    snoc t (SolvedType a τ) = pure (Type.solveType a τ t)
    snoc t (SolvedFields a r) = pure (Type.solveFields a r t)
    snoc t (UnsolvedType a) | a `Type.typeFreeIn` t = do
        name <- makeUniqueTyVar

        let domain = Domain.Type

        let type_ = Type.solveType a (Monotype.VariableType name) t

        let location = Type.location t

        let nameLocation = location

        pure Type.Forall{..}
    snoc t _ = pure t

{- | Split a `Context` into two `Context`s before and after the given
   `UnsolvedType` variable.  Neither `Context` contains the variable

   Returns `Nothing` if no such `UnsolvedType` variable is present within the
   `Context`
-}
splitOnUnsolvedType ::
    -- | `UnsolvedType` variable to split on
    Existential Monotype ->
    Context s ->
    Maybe (Context s, Context s)
splitOnUnsolvedType a0 (UnsolvedType a1 : entries) | a0 == a1 = pure ([], entries)
splitOnUnsolvedType a (entry : entries) = do
    (prefix, suffix) <- splitOnUnsolvedType a entries
    pure (entry : prefix, suffix)
splitOnUnsolvedType _ [] = Nothing

{- | Split a `Context` into two `Context`s before and after the given
   `UnsolvedFields` variable.  Neither `Context` contains the variable

   Returns `Nothing` if no such `UnsolvedFields` variable is present within the
   `Context`
-}
splitOnUnsolvedFields ::
    -- | `UnsolvedFields` variable to split on
    Existential Monotype.Record ->
    Context s ->
    Maybe (Context s, Context s)
splitOnUnsolvedFields p0 (UnsolvedFields p1 : entries)
    | p0 == p1 = pure ([], entries)
splitOnUnsolvedFields p (entry : entries) = do
    (prefix, suffix) <- splitOnUnsolvedFields p entries
    pure (entry : prefix, suffix)
splitOnUnsolvedFields _ [] = Nothing

{- | Split a `Context` into two `Context`s before and after the given
   `UnsolvedAlternatives` variable.  Neither `Context` contains the variable

   Returns `Nothing` if no such `UnsolvedAlternatives` variable is present
   within the `Context`
-}
splitOnUnsolvedAlternatives ::
    -- | `UnsolvedAlternatives` variable to split on
    Existential Monotype.Union ->
    Context s ->
    Maybe (Context s, Context s)
splitOnUnsolvedAlternatives p0 (UnsolvedAlternatives p1 : entries)
    | p0 == p1 = pure ([], entries)
splitOnUnsolvedAlternatives p (entry : entries) = do
    (prefix, suffix) <- splitOnUnsolvedAlternatives p entries
    pure (entry : prefix, suffix)
splitOnUnsolvedAlternatives _ [] = Nothing

{- | Retrieve a variable's annotated type from a `Context`, given the variable's
   label and index

>>> :{
let
   x0 = Local (IgnoreLocation (Located undefined (unsafeMkUnique (NVarName "x") 0)))
   y1 = Local (IgnoreLocation (Located undefined (unsafeMkUnique (NVarName "y") 1)))
   x2 = Local (IgnoreLocation (Located undefined (unsafeMkUnique (NVarName "x") 2)))
in lookup
       x0
       [ Annotation x0 (Type.Scalar () Monotype.Bool)
       , Annotation y1 (Type.Scalar () Monotype.Natural)
       , Annotation x2 (Type.Scalar () Monotype.Text)
       ]
:}
Just (Scalar {location = (), scalar = Bool})
-}
lookup ::
    -- | Variable label
    IgnoreLocVarRef Name ->
    Context s ->
    Maybe (Type s)
lookup _ [] = Nothing
lookup x0 (Annotation x1 _A : _Γ) = if x0 == x1 then Just _A else lookup x0 _Γ
lookup x (_ : _Γ) = lookup x _Γ

-- | Discard all entries from a `Context` up to and including the given `Entry`
discardUpTo :: Eq s => Entry s -> Context s -> Context s
discardUpTo entry0 (entry1 : _Γ)
    | entry0 == entry1 = _Γ
    | otherwise = discardUpTo entry0 _Γ
discardUpTo _ [] = []

-- | Discard all entries from a `Context` up to the given `Entry`
discardUpToExcluding :: Eq s => Entry s -> Context s -> Context s
discardUpToExcluding entry0 (entry1 : _Γ)
    | entry0 == entry1 = []
    | otherwise = entry1 : discardUpToExcluding entry0 _Γ
discardUpToExcluding _ [] = []

-- newtype ContextGraph s = ContextGraph (TopologicalGraph (SolvedTypeEntry s))
--     deriving (Pretty, Show)

-- simplifyContext :: Context () -> ContextGraph ()
-- simplifyContext context = (ContextGraph . addAnnotations . createGraph . mapMaybe toEntry) $ context
--   where
--     toEntry :: Entry () -> Maybe (SolvedTypeEntry ())
--     toEntry entry = case entry of
--         SolvedType a τ -> Just (SolvedTypeEntry (Type.fromMonotype τ, [Type.fromMonotype $ Monotype.UnsolvedType a]))
--         _ -> Nothing

--     addAnnotations :: TopologicalGraph (SolvedTypeEntry ()) -> TopologicalGraph (SolvedTypeEntry ())
--     addAnnotations graph = foldr addAnnotationsForEQ graph annotations
--       where
--         annotations = groupAnnotations $ mapMaybe toAnnotation context

--         toAnnotation :: Entry () -> Maybe ((IgnoreLocVarRef Name), (Type ()))
--         toAnnotation = preview (_Ctor' @"Annotation")

--         groupAnnotations :: [(IgnoreLocVarRef Name, Type ())] -> [(IgnoreLocVarRef Name, NonEmpty (Type ()))]
--         groupAnnotations [] = []
--         groupAnnotations ((k, v) : xs) = (k, v :| map snd ys) : groupAnnotations zs
--           where
--             (ys, zs) = span ((== k) . fst) xs

--         -- Add annotations for a group of annotations with the same key
--         -- this essentially adds an edge between every type in the group in
--         addAnnotationsForEQ :: (IgnoreLocVarRef Name, NonEmpty (Type ())) -> TopologicalGraph (SolvedTypeEntry ()) -> TopologicalGraph (SolvedTypeEntry ())
--         addAnnotationsForEQ (name, types) graph = foldr addEdgeForType graph types
--           where
--             addEdgeForType :: Type () -> TopologicalGraph (SolvedTypeEntry ()) -> TopologicalGraph (SolvedTypeEntry ())
--             addEdgeForType t g =
--                 let others = NE.filter (/= t) types
--                  in case moduleFromName t g of
--                         Nothing -> addNode (SolvedTypeEntry (t, others)) g
--                         Just (SolvedTypeEntry (a, bs)) -> replaceNodeAt t (SolvedTypeEntry (t, others ++ bs)) g

-- newtype SolvedTypeEntry s = SolvedTypeEntry (Type s, [Type s])
--     deriving (Eq, Pretty, Show, Ord)

-- instance Ord s => HasDependencies (SolvedTypeEntry s) where
--     type Key (SolvedTypeEntry s) = Type s

--     keys :: SolvedTypeEntry s -> NonEmpty (Type s)
--     keys (SolvedTypeEntry (b, _)) = b :| []

--     dependencies :: SolvedTypeEntry s -> [Type s]
--     dependencies (SolvedTypeEntry (_, extraDeps)) = extraDeps

newtype ContextGraph = ContextGraph (Graph (Type ())) deriving (Show, Pretty)

instance (Show s, Ord s) => Pretty (Graph (Type s)) where
    pretty graph = pretty @Text $ export (defaultStyle prettyToUnannotatedText) $ fromUndirected graph

simplifyContext :: Context () -> ContextGraph
simplifyContext context = ContextGraph $ addAnnotationEdges $ foldMap toEntry context
  where
    toEntry entry = case entry of
        SolvedType a τ -> let a' = Type.UnsolvedType () a in let τ' = Type.fromMonotype τ in edge a' τ'
        _ -> empty

    addAnnotationEdges :: Graph (Type ()) -> Graph (Type ())
    addAnnotationEdges graph = foldr addAnnotationEdge graph annotations
      where
        annotations = groupAnnotations $ mapMaybe toAnnotation context

        toAnnotation :: Entry () -> Maybe (IgnoreLocVarRef Name, Type ())
        toAnnotation = preview (_Ctor' @"Annotation")

        groupAnnotations :: [(IgnoreLocVarRef Name, Type ())] -> [(IgnoreLocVarRef Name, NonEmpty (Type ()))]
        groupAnnotations [] = []
        groupAnnotations ((k, v) : xs) = (k, v :| map snd ys) : groupAnnotations zs
          where
            (ys, zs) = span ((== k) . fst) xs

        addAnnotationEdge :: (IgnoreLocVarRef Name, NonEmpty (Type ())) -> Graph (Type ()) -> Graph (Type ())
        addAnnotationEdge (name, types) graph = foldr addEdgeForType graph types
          where
            addEdgeForType :: Type () -> Graph (Type ()) -> Graph (Type ())
            addEdgeForType t g =
                let others = NE.filter (/= t) types
                 in foldr (overlay . edge t) g others

{- | "Unifies" a `ContextGraph`
This is the core functionality of unifying a context and works by unifying neighbours of nodes
For example, consider the following context:
@
(h? -> i?) <-> e <-> forall a. a -> a
@

We can look at the 2 neighbours of @e@ to deduce that @h = a@ and @i = a@, creating new `SolvedType`s
-}
unifyContextGraph :: Member StructuredDebug r => ContextGraph -> Sem r ContextGraph
unifyContextGraph (ContextGraph graph) = fmap ContextGraph $ fmap fst <$> runState graph $ do
    for_ (vertexList graph) $ \vertex -> do
        let adjacent = neighbours vertex graph
        unify (toList adjacent)
  where
    modify_ = modify . overlay
    unify :: [Type ()] -> Sem _ ()
    unify adj = debugWith ("unifyGraph: " <> showPretty adj) $ do
        for_ adj $ \adjacent -> do
            for_ adj $ \adjacent' -> do
                when (adjacent /= adjacent') $ do
                    unify' adjacent adjacent'

    unify' :: Type () -> Type () -> Sem _ ()
    unify' unsolved solved | unsolved == solved = pass
    unify' unsolved solved = debugWith ("unifyGraph: " <> showPretty (unsolved, solved)) $
        case (Type.stripForAll unsolved, Type.stripForAll solved) of
            (Type.Function{input = unsolvedInput, output = unsolvedOutput}, Type.Function{input = solvedInput, output = solvedOutput}) -> do
                subst unsolvedInput solvedInput
                unify' unsolvedInput solvedInput
                subst unsolvedOutput solvedOutput
                unify' unsolvedOutput solvedOutput
            (Type.VariableType{}, out) -> subst unsolved out
            (Type.UnsolvedType{}, out) -> subst unsolved out
            (out, Type.UnsolvedType{}) -> subst solved out
            other -> error (showPretty other)

    subst :: Type () -> Type () -> Sem _ ()
    subst t@Type.UnsolvedType{} solved = debugWith ("subst: " <> showPretty (t, solved)) $ do
        ctx <- get
        let solvedT = solveType' ctx t
        when (solvedT /= solved) $ do
            -- debug ("subst1: " <> showPretty (solvedT, solved))
            modify_ (edge t solved)
            modify_ (edge solved solvedT)
            ctx <- get
            let solvedAgain = solveType' ctx t
            when (solvedT /= solvedAgain) $ do
                -- debug ("subst2: " <> showPretty (solvedAgain, solved))
                unify' solvedT solvedAgain
    subst a b = pass

-- like normal `solveType` but using edges of the graph
-- given that `SolvedType` entries map to edges in the graph, this needs to solve over _every_ edge
solveType' :: forall s. (Ord s, Show s) => Graph (Type s) -> Type s -> Type s
solveType' graph type_ =
    let g = fromUndirected graph :: Algebraic.Graph.Graph (Type s)
     in let r = reachable g type_ :: [Type s]
         in case filter isSolved r of
                [] -> type_
                [x] -> x
                multiple -> error $ "Multiple solutions found for " <> showPretty type_ <> ": " <> showPretty multiple <> " in " <> showPretty graph
  where
    isSolved :: Type s -> Bool
    isSolved = hasn't (cosmosOf plate % _As @"UnsolvedType")

solveFromGraph :: ContextGraph -> Type () -> Type ()
solveFromGraph (ContextGraph graph) = solveType' graph

graphToContext :: ContextGraph -> Context ()
graphToContext (ContextGraph graph) = mapMaybe toEntry $ edgeList graph
  where
    toEntry :: (Type (), Type ()) -> Maybe (Entry ())
    toEntry (Type.UnsolvedType _ a, b@Type.Forall{}) = Nothing
    toEntry (Type.UnsolvedType _ a, b) = Just $ SolvedType a (Type.toMonoType b)
    toEntry (b, Type.UnsolvedType _ a) = Just $ SolvedType a (Type.toMonoType b)
    toEntry _ = Nothing
