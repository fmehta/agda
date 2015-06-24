{-# OPTIONS_GHC -Wall #-}
-- GHC 7.4.2 requires this layout for the pragmas. See Issue 1460.
{-# LANGUAGE CPP,
             DoAndIfThenElse,
             ScopedTypeVariables #-}
module Agda.Compiler.ToTreeless
  ( ifToTreeless
  , ccToTreeless
  ) where

import Control.Monad.Reader
import Data.Maybe
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Traversable (traverse)

import Agda.Syntax.Internal (QName)
import qualified Agda.Syntax.Treeless as C
import qualified Agda.Syntax.Internal as I
import qualified Agda.Syntax.Literal as TL
import qualified Agda.TypeChecking.CompiledClause as CC
import Agda.TypeChecking.Records (getRecordConstructor)
import Agda.TypeChecking.Pretty

import Agda.Syntax.Common
import Agda.TypeChecking.Monad as TCM

import Agda.Utils.Functor
import qualified Agda.Utils.HashMap as HMap
import Agda.Utils.List
import Agda.Utils.Maybe
import Agda.Utils.Monad

#include "undefined.h"
import Agda.Utils.Impossible

-- | Converts a whole module into a Treeless module.
ifToTreeless :: Interface -> TCM C.TModule
ifToTreeless iface = do
  let defns = HMap.toList $ sigDefinitions $ iSignature iface
  funs <- forDefs defns $ \nm def mkCDef -> do
    case theDef def of
      f@(Function {}) -> do
        reportSDoc "treeless.convert" 20 $ text "converting fun:" <+> prettyTCM nm
        let cc = fromMaybe __IMPOSSIBLE__ $ funCompiled $ f

        body' <- ccToTreeless nm cc
        (\x -> [(nm, x)]) <$> mkCDef (C.Fun body')
      (Axiom {}) -> do
        -- TODO compiled stuff
        (\x -> [(nm, x)]) <$> (mkCDef $ C.Fun (C.TError $ C.TAxiomEvaluated nm))
      _ -> return []

--  conInstMp <- getInstantiationMap defns
  cons <- Map.unionsWith (++) <$> (forDefs defns $ \nm def mkCDef -> do
    case theDef def of
      c@(Constructor {}) -> do --- | not (Map.member nm conInstMp) -> do
        con' <- mkCDef $ C.Con nm
        return [Map.singleton (conData c) [con']]
      _ -> return []
    )

  dats <- forDefs defns $ \nm def mkCDef -> do

    case theDef def of
      (Datatype {}) -> do
        let myCons = fromMaybe [] (Map.lookup nm cons)
        (\x -> [(nm, x)]) <$> (mkCDef $ C.Datatype myCons)
      (Record{}) -> do
        let myCon = fromMaybe __IMPOSSIBLE__ (Map.lookup nm cons >>= headMaybe)
        (\x -> [(nm, x)]) <$> (mkCDef $ C.Record myCon)
      _ -> return []


  return $ C.TModule (iModuleName iface) (Map.fromList dats) (Map.fromList funs)

  where
    forDefs :: [(QName, Definition)] -> (QName -> Definition -> (a -> TCM (C.Def a)) -> TCM [b]) -> TCM [b]
    forDefs defs cont = concat <$>
        traverse (\(nm, def) -> cont nm def (return . C.Def nm undefined)) defs


-- | Converts compiled clauses to treeless syntax.
ccToTreeless :: QName -> CC.CompiledClauses -> TCM C.TTerm
ccToTreeless funNm cc = do
  reportSDoc "treeless.convert" 30 $ text "compiled clauses:" <+> (text . show) cc
  body' <- casetree cc `runReaderT` (initCCEnv funNm)
  reportSDoc "treeless.convert" 30 $ text " converted body:" <+> (text . show) body'
  return body'

{-
-- | Maps constructor names to their actual implementation names.
-- Used for instantiated modules, where datatype definitions gets duplicated,
-- but we want to use the original definition when translating.
type ConInstMp = Map.Map QName QName


-- | Computes the constructor instantiation map.
getInstantiationMap :: [(QName, Definition)] -> TCM ConInstMp
getInstantiationMap defs =
  Map.unions <$> traverse (\(n, def) ->
        case theDef def of
            c@(Constructor {}) -> Map.singleton n <$> chaseCon (I.conName $ conSrcCon c)
            r@(Record {}) -> Map.singleton n <$> chaseCon (I.conName $ recConHead r)
            _ -> return Map.empty
        ) defs
  where chaseCon :: QName -> TCM QName
        chaseCon conNm = do
            conDef <- theDef <$> getConstInfo conNm
            let conSrcNm = case conDef of
                    c@(Constructor {}) -> I.conName $ conSrcCon c
                    r@(Record {}) -> I.conName $ recConHead r
                    _ -> __IMPOSSIBLE__
            if conSrcNm == conNm then
              return conSrcNm
            else
              chaseCon conSrcNm
-}


-- | Initial environment for expression generation.
initCCEnv :: QName -> CCEnv
initCCEnv fun = CCEnv
  { ccFunction   = fun
  , ccCxt        = []
  , ccCatchAll   = Nothing
  }

-- | Environment for naming of local variables.
--   Invariant: @reverse ccCxt ++ ccNameSupply@
data CCEnv = CCEnv
  { ccFunction   :: QName
  , ccCxt        :: CCContext  -- ^ Maps case tree de-bruijn indices to TTerm de-bruijn indices
  , ccCatchAll   :: Maybe Int  -- ^ de-bruijn index of the current catch all
  -- If an inner case has no catch-all clause, we use the one from its parent.
  }

type CCContext = [Int]
type CC = ReaderT CCEnv TCM

shift :: Int -> CCContext -> CCContext
shift n = map (+n)

-- | Term variables are de Bruijn indices.
lookupIndex :: Int -> CCContext -> Int
lookupIndex i xs = fromMaybe __IMPOSSIBLE__ $ xs !!! i

-- | Case variables are de Bruijn levels.
lookupLevel :: Int -> CCContext -> Int
lookupLevel l xs = fromMaybe __IMPOSSIBLE__ $ xs !!! (length xs - 1 - l)

patMatchFailure :: CC C.TTerm
patMatchFailure = do
  fun <- asks ccFunction
  return $ C.TError $ C.TPatternMatchFailure fun

-- | Compile a case tree into nested case and record expressions.
casetree :: CC.CompiledClauses -> CC C.TTerm
casetree cc = do
  case cc of
    CC.Fail -> patMatchFailure
    CC.Done xs v -> lambdasUpTo (length xs) $ do
        substTerm v
    CC.Case n (CC.Branches True conBrs _ _) -> lambdasUpTo n $ do
      mkRecord =<< traverse casetree (CC.content <$> conBrs)
    CC.Case n (CC.Branches False conBrs litBrs catchAll) -> lambdasUpTo (n + 1) $ do
      if Map.null conBrs && Map.null litBrs then do
        -- there are no branches, just return default
        fromMaybe <$> patMatchFailure
            <*> (fmap C.TVar <$> asks ccCatchAll)
      else do
        caseTy <- case (Map.keys conBrs, Map.keys litBrs) of
              ((c:_), []) -> do
                dtNm <- conData . theDef <$> lift (getConstInfo c)
                return $ C.CTData dtNm
              ([], (TL.LitChar _ _):_) -> return C.CTChar
              ([], (TL.LitString _ _):_) -> return C.CTString
              _ -> __IMPOSSIBLE__
        updateCatchAll catchAll $ do
          x <- lookupLevel n <$> asks ccCxt
          -- should this be internal error, or pat match failure by default?
          -- normally, Agda should make sure that a pattern match is total,
          -- so this normally shouldn't happen
          def <- maybe (C.TError C.TInternalError) C.TVar <$> asks ccCatchAll
          C.TCase (C.TVar x) caseTy def <$> do
            br1 <- conAlts n conBrs
            br2 <- litAlts litBrs
            return (br1 ++ br2)

updateCatchAll :: Maybe CC.CompiledClauses -> (CC C.TTerm -> CC C.TTerm)
updateCatchAll Nothing cont = cont
updateCatchAll (Just cc) cont = do
  def <- casetree cc
  local (\e -> e { ccCatchAll = Just 0, ccCxt = shift 1 (ccCxt e) }) $ do
    C.mkLet def <$> cont

lambdasUpTo :: Int -> CC C.TTerm -> CC C.TTerm
lambdasUpTo n cont = do
  diff <- max 0 . (n -) . length <$> asks ccCxt

  if diff == 0 then cont
  else do
    catchAll <- asks ccCatchAll

    local (\e -> e { ccCxt = [0..(diff - 1)] ++ shift diff (ccCxt e)}) $ do
      createLambdas diff <$> do
        case catchAll of
          Just catchAll' -> do
            -- the catch all doesn't know about the additional lambdas, so just directly apply it
            -- to the arg
            -- we also bind the catch all to a let, to avoid code duplication
            local (\e -> e { ccCatchAll = Just 0
                           , ccCxt = shift 1 (ccCxt e)}) $ do
              let catchAllArgs = map C.TVar [(diff - 1)..0]
              C.mkLet (C.mkTApp (C.TVar $ catchAll' + diff) catchAllArgs)
                <$> cont
          Nothing -> cont
  where createLambdas :: Int -> C.TTerm -> C.TTerm
        createLambdas 0 cont' = cont'
        createLambdas i cont' | i > 0 = C.TLam (createLambdas (i - 1) cont')
        createLambdas _ _ = __IMPOSSIBLE__

conAlts :: Int -> Map QName (CC.WithArity CC.CompiledClauses) -> CC [C.TAlt]
conAlts x br = forM (Map.toList br) $ \ (c, CC.WithArity n cc) -> do
  replaceVar x n $ do
    branch (C.TACon c) cc

litAlts :: Map TL.Literal CC.CompiledClauses -> CC [C.TAlt]
litAlts br = forM (Map.toList br) $ \ (l, cc) ->
  -- TODO: substitute in ccCatchAll somehow
  let mkAlt = case l of
        TL.LitChar _ c -> C.TAChar c
        TL.LitString _ s -> C.TAString s
        _ -> __IMPOSSIBLE__
   in branch mkAlt cc

branch :: (C.TTerm -> C.TAlt) -> CC.CompiledClauses -> CC C.TAlt
branch alt cc = do
  alt <$> casetree cc

-- | Replace de Bruijn Level @x@ by @n@ new variables.
replaceVar :: Int -> Int -> CC a -> CC a
replaceVar x n cont = do
  let upd cxt = shift n ys ++ ixs ++ shift n zs -- We reverse xs to get nicer names.
       where
         -- compute the de Bruijn index
         i = length cxt - 1 - x
         -- discard index i
         (ys, _:zs) = splitAt i cxt
         -- compute the de-bruijn indexes of the newly inserted variables
         ixs = [0..(n - 1)]
  local (\e -> e { ccCxt = upd (ccCxt e) , ccCatchAll = (+n) <$> ccCatchAll e }) $
    cont


-- | Precondition: Map not empty.
mkRecord :: Map QName C.TTerm -> CC C.TTerm
mkRecord fs = lift $ do
  -- Get the name of the first field
  let p1 = fst $ fromMaybe __IMPOSSIBLE__ $ headMaybe $ Map.toList fs
  -- Use the field name to get the record constructor and the field names.
  I.ConHead c _ind xs <- recConFromProj p1
  -- Convert the constructor
  let (args :: [C.TTerm]) = for xs $ \ x -> fromMaybe __IMPOSSIBLE__ $ Map.lookup x fs
  return $ C.mkTApp (C.TCon c) args


recConFromProj :: QName -> TCM I.ConHead
recConFromProj q = do
  caseMaybeM (isProjection q) __IMPOSSIBLE__ $ \ proj -> do
    let d = projFromType proj
    getRecordConstructor d


-- | Translate the actual Agda terms, with an environment of all the bound variables
--   from patternmatching. Agda terms are in de Bruijn so we just check the new
--   names in the position.
substTerm :: I.Term -> CC C.TTerm
substTerm term = case I.ignoreSharing $ I.unSpine term of
    I.Var ind es -> do
      ind' <- lookupIndex ind <$> asks ccCxt
      let args = fromMaybe __IMPOSSIBLE__ $ I.allApplyElims es
      C.mkTApp (C.TVar ind') <$> mapM (substTerm . unArg) args
    I.Lam _ ab ->
      C.TLam <$>
        local (\e -> e { ccCxt = 0 : (map (+1) $ ccCxt e) })
          (substTerm $ I.unAbs ab)
    I.Lit l -> return $ C.TLit l
    I.Level _ -> return C.TUnit -- TODO can we really do this here?
    I.Def q es -> do
      let args = fromMaybe __IMPOSSIBLE__ $ I.allApplyElims es
      C.mkTApp (C.TDef q) <$> mapM (substTerm . unArg) args
    I.Con c args ->
        C.mkTApp (C.TCon $I.conName c) <$> mapM (substTerm . unArg) args
    I.Shared _ -> __IMPOSSIBLE__ -- the ignoreSharing fun should already take care of this
    I.Pi _ _ -> return C.TUnit -- TODO return proper pi here
    I.Sort _  -> return C.TSort
    I.MetaV _ _ -> __IMPOSSIBLE__
    I.DontCare _ -> __IMPOSSIBLE__ -- when does this happen?
