%
% (c) The University of Glasgow, 2000
%
\section[CompManager]{The Compilation Manager}

\begin{code}
module CompManager ( 
    cmInit, 	  -- :: GhciMode -> IO CmState
    cmLoadModule, -- :: CmState -> FilePath -> IO (CmState, [String])
    cmUnload,	  -- :: CmState -> IO CmState
    cmTypeOfName, -- :: CmState -> Name -> IO (Maybe String)

    cmSetContext, -- :: CmState -> String -> IO CmState
    cmGetContext, -- :: CmState -> IO String
#ifdef GHCI
    cmRunStmt,	  --  :: CmState -> DynFlags -> String -> IO (CmState, [Name])
#endif
    CmState, emptyCmState  -- abstract
  )
where

#include "HsVersions.h"

import CmLink
import CmTypes
import HscTypes
import RnEnv		( unQualInScope )
import Id		( idType, idName )
import Name		( Name, lookupNameEnv, extendNameEnvList, 
			  NamedThing(..) )
import RdrName		( emptyRdrEnv )
import Module		( Module, ModuleName, moduleName, isHomeModule,
			  mkModuleName, moduleNameUserString, moduleUserString )
import CmStaticInfo	( GhciMode(..) )
import DriverPipeline
import GetImports
import Type		( tidyType )
import VarEnv		( emptyTidyEnv )
import HscTypes
import HscMain		( initPersistentCompilerState )
import Finder
import UniqFM		( lookupUFM, addToUFM, delListFromUFM,
			  UniqFM, listToUFM )
import Unique		( Uniquable )
import Digraph		( SCC(..), stronglyConnComp, flattenSCC )
import DriverFlags	( getDynFlags )
import DriverPhases
import DriverUtil	( splitFilename3 )
import ErrUtils		( showPass )
import Util
import DriverUtil
import TmpFiles
import Outputable
import Panic
import CmdLineOpts	( DynFlags(..) )
import IOExts

#ifdef GHCI
import Interpreter	( HValue )
import HscMain		( hscStmt )
import PrelGHC		( unsafeCoerce# )
#endif

-- lang
import Exception	( throwDyn )

-- std
import Time             ( ClockTime )
import Directory        ( getModificationTime, doesFileExist )
import IO
import Monad
import List		( nub )
import Maybe		( catMaybes, fromMaybe, isJust, fromJust )
\end{code}


\begin{code}
-- Persistent state for the entire system
data CmState
   = CmState {
        hst   :: HomeSymbolTable,    -- home symbol table
        hit   :: HomeIfaceTable,     -- home interface table
        ui    :: UnlinkedImage,      -- the unlinked images
        mg    :: ModuleGraph,        -- the module graph
        gmode :: GhciMode,           -- NEVER CHANGES
	ic    :: InteractiveContext, -- command-line binding info

        pcs    :: PersistentCompilerState, -- compile's persistent state
        pls    :: PersistentLinkerState    -- link's persistent state
     }

emptyCmState :: GhciMode -> Module -> IO CmState
emptyCmState gmode mod
    = do pcs     <- initPersistentCompilerState
         pls     <- emptyPLS
         return (CmState { hst    = emptySymbolTable,
                           hit    = emptyIfaceTable,
                           ui     = emptyUI,
                           mg     = emptyMG, 
                           gmode  = gmode,
			   ic     = emptyInteractiveContext mod,
                           pcs    = pcs,
                           pls    = pls })

emptyInteractiveContext mod
  = InteractiveContext { ic_module = mod, 
			 ic_rn_env = emptyRdrEnv,
			 ic_type_env = emptyTypeEnv }

defaultCurrentModuleName = mkModuleName "Prelude"
GLOBAL_VAR(defaultCurrentModule, error "no defaultCurrentModule", Module)

-- CM internal types
type UnlinkedImage = [Linkable]	-- the unlinked images (should be a set, really)
emptyUI :: UnlinkedImage
emptyUI = []

type ModuleGraph = [ModSummary]  -- the module graph, topologically sorted
emptyMG :: ModuleGraph
emptyMG = []

-----------------------------------------------------------------------------
-- Produce an initial CmState.

cmInit :: GhciMode -> IO CmState
cmInit mode = do
   prel <- moduleNameToModule defaultCurrentModuleName
   writeIORef defaultCurrentModule prel
   emptyCmState mode prel

-----------------------------------------------------------------------------
-- Setting the context doesn't throw away any bindings; the bindings
-- we've built up in the InteractiveContext simply move to the new
-- module.  They always shadow anything in scope in the current context.

cmSetContext :: CmState -> String -> IO CmState
cmSetContext cmstate str
   = do let mn = mkModuleName str
	    modules_loaded = [ (name_of_summary s, ms_mod s)  | s <- mg cmstate ]

        m <- case lookup mn modules_loaded of
		Just m  -> return m
		Nothing -> do
		   mod <- moduleNameToModule mn
		   if isHomeModule mod 
			then throwDyn (OtherError (showSDoc 
				(quotes (ppr (moduleName mod))
 				  <+> text "is not currently loaded")))
		   	else return mod

	return cmstate{ ic = (ic cmstate){ic_module=m} }
		
cmGetContext :: CmState -> IO String
cmGetContext cmstate = return (moduleUserString (ic_module (ic cmstate)))

moduleNameToModule :: ModuleName -> IO Module
moduleNameToModule mn
 = do maybe_stuff <- findModule mn
      case maybe_stuff of
	Nothing -> throwDyn (OtherError ("can't find module `"
				    ++ moduleNameUserString mn ++ "'"))
	Just (m,_) -> return m

-----------------------------------------------------------------------------
-- cmRunStmt:  Run a statement/expr.

#ifdef GHCI
cmRunStmt :: CmState -> DynFlags -> String -> IO (CmState, [Name])
cmRunStmt cmstate dflags expr
   = do 
	let icontext = ic cmstate
	    InteractiveContext { 
	       	ic_rn_env = rn_env, 
	       	ic_type_env = type_env,
	       	ic_module   = this_mod } = icontext

        (new_pcs, maybe_stuff) <- hscStmt dflags hst hit pcs icontext expr
        case maybe_stuff of
	   Nothing -> return (cmstate{ pcs=new_pcs }, [])
	   Just (ids, bcos) -> do
	        let 
		    new_rn_env   = extendLocalRdrEnv rn_env (map idName ids)

			-- Extend the renamer-env from bound_ids, not
			-- bound_names, because the latter may contain
			-- [it] when the former is empty
		    new_type_env = extendNameEnvList type_env 	
			      		[ (getName id, AnId id)	| id <- ids]

		    new_ic = icontext { ic_rn_env   = new_rn_env, 
			  	  	ic_type_env = new_type_env }

		hval <- linkExpr pls bcos
		hvals <- unsafeCoerce# hval :: IO [HValue]
		let names = map idName ids
		new_pls <- updateClosureEnv pls (zip names hvals)
	        return (cmstate{ pcs=new_pcs, pls=new_pls, ic=new_ic }, names)

   -- ToDo: check that the module we passed in is sane/exists?
   where
       CmState{ hst=hst, hit=hit, pcs=pcs, pls=pls } = cmstate
#endif

-----------------------------------------------------------------------------
-- cmTypeOf: returns a string representing the type of a name.

cmTypeOfName :: CmState -> Name -> IO (Maybe String)
cmTypeOfName CmState{ hit=hit, pcs=pcs, ic=ic } name
 = case lookupNameEnv (ic_type_env ic) name of
	Nothing -> return Nothing
	Just (AnId id) -> 
	   let pit = pcs_PIT pcs
	       modname = moduleName (ic_module ic)
	       ty = tidyType emptyTidyEnv (idType id)
	       str = case lookupIfaceByModName hit pit modname of
			Nothing    -> showSDoc (ppr ty)
			Just iface -> showSDocForUser unqual (ppr ty)
		  	   where unqual = unQualInScope (mi_globals iface)
	   in return (Just str)

	_ -> panic "cmTypeOfName"

-----------------------------------------------------------------------------
-- cmInfo: return "info" about an expression.  The info might be:
--
--	* its type, for an expression,
--	* the class definition, for a class
--	* the datatype definition, for a tycon (or synonym)
--	* the export list, for a module
--
-- Can be used to find the type of the last expression compiled, by looking
-- for "it".

cmInfo :: CmState -> String -> IO (Maybe String)
cmInfo cmstate str 
 = do error "cmInfo not implemented yet"

-----------------------------------------------------------------------------
-- Unload the compilation manager's state: everything it knows about the
-- current collection of modules in the Home package.

cmUnload :: CmState -> IO CmState
cmUnload state 
 = do -- Throw away the old home dir cache
      emptyHomeDirCache
      -- Throw away the HIT and the HST
      return state{ hst=new_hst, hit=new_hit, ui=emptyUI }
   where
     CmState{ hst=hst, hit=hit } = state
     (new_hst, new_hit) = retainInTopLevelEnvs [] (hst,hit)

-----------------------------------------------------------------------------
-- The real business of the compilation manager: given a system state and
-- a module name, try and bring the module up to date, probably changing
-- the system state at the same time.

cmLoadModule :: CmState 
             -> FilePath
             -> IO (CmState,		-- new state
		    Bool, 		-- was successful
		    [String])		-- list of modules loaded

cmLoadModule cmstate1 rootname
   = do -- version 1's are the original, before downsweep
        let pls1      = pls    cmstate1
        let pcs1      = pcs    cmstate1
        let hst1      = hst    cmstate1
        let hit1      = hit    cmstate1
	-- similarly, ui1 is the (complete) set of linkables from
	-- the previous pass, if any.
        let ui1       = ui     cmstate1
   	let mg1       = mg     cmstate1
   	let ic1       = ic     cmstate1

        let ghci_mode = gmode cmstate1 -- this never changes

        -- Do the downsweep to reestablish the module graph
        -- then generate version 2's by retaining in HIT,HST,UI a
        -- stable set S of modules, as defined below.

	dflags <- getDynFlags
        let verb = verbosity dflags

	showPass dflags "Chasing dependencies"
        when (verb >= 1 && ghci_mode == Batch) $
           hPutStrLn stderr (progName ++ ": chasing modules from: " ++ rootname)

        (mg2unsorted, a_root_is_Main) <- downsweep [rootname] mg1
        let mg2unsorted_names = map name_of_summary mg2unsorted

        -- reachable_from follows source as well as normal imports
        let reachable_from :: ModuleName -> [ModuleName]
            reachable_from = downwards_closure_of_module mg2unsorted
 
        -- should be cycle free; ignores 'import source's
        let mg2 = topological_sort False mg2unsorted
        -- ... whereas this takes them into account.  Used for
        -- backing out partially complete cycles following a failed
        -- upsweep, and for removing from hst/hit all the modules
        -- not in strict downwards closure, during calls to compile.
        let mg2_with_srcimps = topological_sort True mg2unsorted

	-- Sort out which linkables we wish to keep in the unlinked image.
	-- See getValidLinkables below for details.
	valid_linkables <- getValidLinkables ui1 mg2unsorted_names 
				mg2_with_srcimps

        -- Figure out a stable set of modules which can be retained
        -- the top level envs, to avoid upsweeping them.  Goes to a
        -- bit of trouble to avoid upsweeping module cycles.
        --
        -- Construct a set S of stable modules like this:
        -- Travel upwards, over the sccified graph.  For each scc
        -- of modules ms, add ms to S only if:
        -- 1.  All home imports of ms are either in ms or S
        -- 2.  A valid linkable exists for each module in ms

        stable_mods
           <- preUpsweep valid_linkables ui1 mg2unsorted_names
		 [] mg2_with_srcimps

        let stable_summaries
               = concatMap (findInSummaries mg2unsorted) stable_mods

	    stable_linkables
	       = filter (\m -> linkableModName m `elem` stable_mods) 
		    valid_linkables

        when (verb >= 2) $
           putStrLn (showSDoc (text "Stable modules:" 
                               <+> sep (map (text.moduleNameUserString) stable_mods)))

	-- unload any modules which aren't going to be re-linked this
	-- time around.
	pls2 <- unload ghci_mode dflags stable_linkables pls1

        -- We could at this point detect cycles which aren't broken by
        -- a source-import, and complain immediately, but it seems better
        -- to let upsweep_mods do this, so at least some useful work gets
        -- done before the upsweep is abandoned.
        let upsweep_these
               = filter (\scc -> any (`notElem` stable_mods) 
                                     (map name_of_summary (flattenSCC scc)))
                        mg2

        --hPutStrLn stderr "after tsort:\n"
        --hPutStrLn stderr (showSDoc (vcat (map ppr mg2)))

        -- Because we don't take into account source imports when doing
        -- the topological sort, there shouldn't be any cycles in mg2.
        -- If there is, we complain and give up -- the user needs to
        -- break the cycle using a boot file.

        -- Now do the upsweep, calling compile for each module in
        -- turn.  Final result is version 3 of everything.

        let threaded2 = CmThreaded pcs1 hst1 hit1

        (upsweep_complete_success, threaded3, modsUpswept, newLis)
           <- upsweep_mods ghci_mode dflags valid_linkables reachable_from 
                           threaded2 upsweep_these

        let ui3 = add_to_ui valid_linkables newLis
        let (CmThreaded pcs3 hst3 hit3) = threaded3

        -- At this point, modsUpswept and newLis should have the same
        -- length, so there is one new (or old) linkable for each 
        -- mod which was processed (passed to compile).

	-- Make modsDone be the summaries for each home module now
	-- available; this should equal the domains of hst3 and hit3.
	-- (NOT STRICTLY TRUE if an interactive session was started
	--  with some object on disk ???)
        -- Get in in a roughly top .. bottom order (hence reverse).

        let modsDone = reverse modsUpswept ++ stable_summaries

        -- Try and do linking in some form, depending on whether the
        -- upsweep was completely or only partially successful.

        if upsweep_complete_success

         then 
           -- Easy; just relink it all.
           do when (verb >= 2) $ 
		 hPutStrLn stderr "Upsweep completely successful."

	      -- clean up after ourselves
	      cleanTempFilesExcept verb (ppFilesFromSummaries modsDone)

	      -- link everything together
              linkresult <- link ghci_mode dflags a_root_is_Main ui3 pls2

	      cmLoadFinish True linkresult 
			hst3 hit3 ui3 modsDone ghci_mode pcs3

         else 
           -- Tricky.  We need to back out the effects of compiling any
           -- half-done cycles, both so as to clean up the top level envs
           -- and to avoid telling the interactive linker to link them.
           do when (verb >= 2) $
		hPutStrLn stderr "Upsweep partially successful."

              let modsDone_names
                     = map name_of_summary modsDone
              let mods_to_zap_names 
                     = findPartiallyCompletedCycles modsDone_names 
			  mg2_with_srcimps
              let (hst4, hit4, ui4)
                     = removeFromTopLevelEnvs mods_to_zap_names (hst3,hit3,ui3)

              let mods_to_keep
                     = filter ((`notElem` mods_to_zap_names).name_of_summary) 
			  modsDone

	      -- clean up after ourselves
	      cleanTempFilesExcept verb (ppFilesFromSummaries mods_to_keep)

	      -- link everything together
              linkresult <- link ghci_mode dflags False ui4 pls2

	      cmLoadFinish False linkresult 
		    hst4 hit4 ui4 mods_to_keep ghci_mode pcs3


-- Finish up after a cmLoad.
--
-- Empty the interactive context and set the module context to the topmost
-- newly loaded module, or the Prelude if none were loaded.
cmLoadFinish ok linkresult hst hit ui mods ghci_mode pcs
  = do case linkresult of {
          LinkErrs _ _ -> panic "cmLoadModule: link failed (2)";
          LinkOK pls   -> do

       def_mod <- readIORef defaultCurrentModule
       let current_mod = case mods of 
				[]    -> def_mod
				(x:_) -> ms_mod x

       	   new_ic = emptyInteractiveContext current_mod

           new_cmstate = CmState{ hst=hst, hit=hit, 
                                  ui=ui, mg=mods,
                                  gmode=ghci_mode, pcs=pcs, 
				  pls=pls,
				  ic = new_ic }
           mods_loaded = map (moduleNameUserString.name_of_summary) mods

       return (new_cmstate, ok, mods_loaded)
    }

ppFilesFromSummaries summaries
  = [ fn | Just fn <- map (ml_hspp_file . ms_location) summaries ]

-----------------------------------------------------------------------------
-- getValidLinkables

-- For each module (or SCC of modules), we take:
--
--	- the old in-core linkable, if available
--	- an on-disk linkable, if available
--
-- and we take the youngest of these, provided it is younger than the
-- source file.  We ignore the on-disk linkables unless all of the
-- dependents of this SCC also have on-disk linkables.
--
-- If a module has a valid linkable, then it may be STABLE (see below),
-- and it is classified as SOURCE UNCHANGED for the purposes of calling
-- compile.
--
-- ToDo: this pass could be merged with the preUpsweep.

getValidLinkables
	:: [Linkable]		-- old linkables
	-> [ModuleName]		-- all home modules
	-> [SCC ModSummary]	-- all modules in the program, dependency order
	-> IO [Linkable]	-- still-valid linkables 

getValidLinkables old_linkables all_home_mods module_graph
  = foldM (getValidLinkablesSCC old_linkables all_home_mods) [] module_graph

getValidLinkablesSCC old_linkables all_home_mods new_linkables scc0
   = let 
	  scc             = flattenSCC scc0
          scc_names       = map name_of_summary scc
	  home_module m   = m `elem` all_home_mods && m `notElem` scc_names
          scc_allhomeimps = nub (filter home_module (concatMap ms_allimps scc))

	  has_object m = case findModuleLinkable_maybe new_linkables m of
			    Nothing -> False
			    Just l  -> isObjectLinkable l

          objects_allowed = all has_object scc_allhomeimps
     in do

     these_linkables 
	<- foldM (getValidLinkable old_linkables objects_allowed) [] scc

	-- since an scc can contain only all objects or no objects at all,
	-- we have to check whether we got all objects or not, and re-do
	-- the linkable check if not.
     adjusted_linkables 
	<- if objects_allowed && not (all isObjectLinkable these_linkables)
	      then foldM (getValidLinkable old_linkables False) [] scc
	      else return these_linkables

     return (adjusted_linkables ++ new_linkables)


getValidLinkable :: [Linkable] -> Bool -> [Linkable] -> ModSummary 
	-> IO [Linkable]
getValidLinkable old_linkables objects_allowed new_linkables summary 
   = do 
	let mod_name = name_of_summary summary

	maybe_disk_linkable
           <- if (not objects_allowed)
		then return Nothing
		else case ml_obj_file (ms_location summary) of
                 	Just obj_fn -> maybe_getFileLinkable mod_name obj_fn
                 	Nothing -> return Nothing

	 -- find an old in-core linkable if we have one. (forget about
	 -- on-disk linkables for now, we'll check again whether there's
	 -- one here below, just in case a new one has popped up recently).
        let old_linkable = findModuleLinkable_maybe old_linkables mod_name
            maybe_old_linkable =
	 	case old_linkable of
	    	    Just (LM _ _ ls) | all isInterpretable ls -> old_linkable
	    	    _ -> Nothing

        -- The most recent of the old UI linkable or whatever we could
        -- find on disk is returned as the linkable if compile
        -- doesn't think we need to recompile.        
        let linkable_list
               = case (maybe_old_linkable, maybe_disk_linkable) of
                    (Nothing, Nothing) -> []
                    (Nothing, Just di) -> [di]
                    (Just ui, Nothing) -> [ui]
                    (Just ui, Just di)
                       | linkableTime ui >= linkableTime di -> [ui]
                       | otherwise                          -> [di]

        -- only linkables newer than the source code are valid
        let maybe_src_date = ms_hs_date summary

	    valid_linkable_list
	      = case maybe_src_date of
		  Nothing -> panic "valid_linkable_list"
		  Just src_date	
		     -> filter (\li -> linkableTime li > src_date) linkable_list

        return (valid_linkable_list ++ new_linkables)


maybe_getFileLinkable :: ModuleName -> FilePath -> IO (Maybe Linkable)
maybe_getFileLinkable mod_name obj_fn
   = do obj_exist <- doesFileExist obj_fn
        if not obj_exist 
         then return Nothing 
         else 
         do let stub_fn = case splitFilename3 obj_fn of
                             (dir, base, ext) -> dir ++ "/" ++ base ++ ".stub_o"
            stub_exist <- doesFileExist stub_fn
            obj_time <- getModificationTime obj_fn
            if stub_exist
             then return (Just (LM obj_time mod_name [DotO obj_fn, DotO stub_fn]))
             else return (Just (LM obj_time mod_name [DotO obj_fn]))


-----------------------------------------------------------------------------
-- Do a pre-upsweep without use of "compile", to establish a 
-- (downward-closed) set of stable modules for which we won't call compile.

preUpsweep :: [Linkable]	-- new valid linkables
	   -> [Linkable]	-- old linkables
           -> [ModuleName]      -- names of all mods encountered in downsweep
           -> [ModuleName]      -- accumulating stable modules
           -> [SCC ModSummary]  -- scc-ified mod graph, including src imps
           -> IO [ModuleName]	-- stable modules

preUpsweep valid_lis old_lis all_home_mods stable [] 
   = return stable
preUpsweep valid_lis old_lis all_home_mods stable (scc0:sccs)
   = do let scc = flattenSCC scc0
            scc_allhomeimps :: [ModuleName]
            scc_allhomeimps 
               = nub (filter (`elem` all_home_mods) (concatMap ms_allimps scc))
            all_imports_in_scc_or_stable
               = all in_stable_or_scc scc_allhomeimps
            scc_names
               = map name_of_summary scc
            in_stable_or_scc m
               = m `elem` scc_names || m `elem` stable

	    -- now we check for valid linkables: each module in the SCC must 
	    -- have a valid linkable (see getValidLinkables above), and the
	    -- newest linkable must be the same as the previous linkable for
	    -- this module (if one exists).
	    has_valid_linkable new_summary
   	      = case findModuleLinkable_maybe valid_lis modname of
		   Nothing -> False
		   Just l  -> case findModuleLinkable_maybe old_lis modname of
				Nothing -> True
				Just m  -> linkableTime l == linkableTime m
	       where modname = name_of_summary new_summary

	    scc_is_stable = all_imports_in_scc_or_stable
			  && all has_valid_linkable scc

        if scc_is_stable
         then preUpsweep valid_lis old_lis all_home_mods 
		(scc_names++stable) sccs
         else preUpsweep valid_lis old_lis all_home_mods 
		stable sccs

   where 


-- Helper for preUpsweep.  Assuming that new_summary's imports are all
-- stable (in the sense of preUpsweep), determine if new_summary is itself
-- stable, and, if so, in batch mode, return its linkable.
findInSummaries :: [ModSummary] -> ModuleName -> [ModSummary]
findInSummaries old_summaries mod_name
   = [s | s <- old_summaries, name_of_summary s == mod_name]

findModInSummaries :: [ModSummary] -> Module -> Maybe ModSummary
findModInSummaries old_summaries mod
   = case [s | s <- old_summaries, ms_mod s == mod] of
	 [] -> Nothing
	 (s:_) -> Just s

-- Return (names of) all those in modsDone who are part of a cycle
-- as defined by theGraph.
findPartiallyCompletedCycles :: [ModuleName] -> [SCC ModSummary] -> [ModuleName]
findPartiallyCompletedCycles modsDone theGraph
   = chew theGraph
     where
        chew [] = []
        chew ((AcyclicSCC v):rest) = chew rest    -- acyclic?  not interesting.
        chew ((CyclicSCC vs):rest)
           = let names_in_this_cycle = nub (map name_of_summary vs)
                 mods_in_this_cycle  
                    = nub ([done | done <- modsDone, 
                                   done `elem` names_in_this_cycle])
                 chewed_rest = chew rest
             in 
             if   not (null mods_in_this_cycle) 
                  && length mods_in_this_cycle < length names_in_this_cycle
             then mods_in_this_cycle ++ chewed_rest
             else chewed_rest


-- Add the given (LM-form) Linkables to the UI, overwriting previous
-- versions if they exist.
add_to_ui :: UnlinkedImage -> [Linkable] -> UnlinkedImage
add_to_ui ui lis
   = filter (not_in lis) ui ++ lis
     where
        not_in :: [Linkable] -> Linkable -> Bool
        not_in lis li
           = all (\l -> linkableModName l /= mod) lis
           where mod = linkableModName li
                                  

data CmThreaded  -- stuff threaded through individual module compilations
   = CmThreaded PersistentCompilerState HomeSymbolTable HomeIfaceTable


-- Compile multiple modules, stopping as soon as an error appears.
-- There better had not be any cyclic groups here -- we check for them.
upsweep_mods :: GhciMode
	     -> DynFlags
             -> UnlinkedImage         -- valid linkables
             -> (ModuleName -> [ModuleName])  -- to construct downward closures
             -> CmThreaded            -- PCS & HST & HIT
             -> [SCC ModSummary]      -- mods to do (the worklist)
                                      -- ...... RETURNING ......
             -> IO (Bool{-complete success?-},
                    CmThreaded,
                    [ModSummary],     -- mods which succeeded
                    [Linkable])       -- new linkables

upsweep_mods ghci_mode dflags oldUI reachable_from threaded 
     []
   = return (True, threaded, [], [])

upsweep_mods ghci_mode dflags oldUI reachable_from threaded 
     ((CyclicSCC ms):_)
   = do hPutStrLn stderr ("Module imports form a cycle for modules:\n\t" ++
                          unwords (map (moduleNameUserString.name_of_summary) ms))
        return (False, threaded, [], [])

upsweep_mods ghci_mode dflags oldUI reachable_from threaded 
     ((AcyclicSCC mod):mods)
   = do --case threaded of
        --   CmThreaded pcsz hstz hitz
        --      -> putStrLn ("UPSWEEP_MOD: hit = " ++ show (map (moduleNameUserString.moduleName.mi_module) (eltsUFM hitz)))

        (threaded1, maybe_linkable) 
           <- upsweep_mod ghci_mode dflags oldUI threaded mod 
                          (reachable_from (name_of_summary mod))
        case maybe_linkable of
           Just linkable 
              -> -- No errors; do the rest
                 do (restOK, threaded2, modOKs, linkables) 
                       <- upsweep_mods ghci_mode dflags oldUI reachable_from 
                                       threaded1 mods
                    return (restOK, threaded2, mod:modOKs, linkable:linkables)
           Nothing -- we got a compilation error; give up now
              -> return (False, threaded1, [], [])


-- Compile a single module.  Always produce a Linkable for it if 
-- successful.  If no compilation happened, return the old Linkable.
upsweep_mod :: GhciMode 
	    -> DynFlags
            -> UnlinkedImage
            -> CmThreaded
            -> ModSummary
            -> [ModuleName]
            -> IO (CmThreaded, Maybe Linkable)

upsweep_mod ghci_mode dflags oldUI threaded1 summary1 reachable_from_here
   = do 
        let mod_name = name_of_summary summary1
	let verb = verbosity dflags

        let (CmThreaded pcs1 hst1 hit1) = threaded1
        let old_iface = lookupUFM hit1 mod_name

        let maybe_old_linkable = findModuleLinkable_maybe oldUI mod_name

            source_unchanged = isJust maybe_old_linkable

            (hst1_strictDC, hit1_strictDC)
               = retainInTopLevelEnvs 
                    (filter (/= (name_of_summary summary1)) reachable_from_here)
                    (hst1,hit1)

            old_linkable 
               = unJust "upsweep_mod:old_linkable" maybe_old_linkable

        compresult <- compile ghci_mode summary1 source_unchanged
                         old_iface hst1_strictDC hit1_strictDC pcs1

        case compresult of

           -- Compilation "succeeded", but didn't return a new
           -- linkable, meaning that compilation wasn't needed, and the
           -- new details were manufactured from the old iface.
           CompOK pcs2 new_details new_iface Nothing
              -> do let hst2         = addToUFM hst1 mod_name new_details
                        hit2         = addToUFM hit1 mod_name new_iface
                        threaded2    = CmThreaded pcs2 hst2 hit2

		    if ghci_mode == Interactive && verb >= 1 then
		      -- if we're using an object file, tell the user
		      case old_linkable of
			(LM _ _ objs@(DotO _:_))
			   -> do hPutStrLn stderr (showSDoc (space <> 
				   parens (hsep (text "using": 
					punctuate comma 
					  [ text o | DotO o <- objs ]))))
			_ -> return ()
		      else
			return ()

                    return (threaded2, Just old_linkable)

           -- Compilation really did happen, and succeeded.  A new
           -- details, iface and linkable are returned.
           CompOK pcs2 new_details new_iface (Just new_linkable)
              -> do let hst2      = addToUFM hst1 mod_name new_details
                        hit2      = addToUFM hit1 mod_name new_iface
                        threaded2 = CmThreaded pcs2 hst2 hit2

	            return (threaded2, Just new_linkable)

           -- Compilation failed.  compile may still have updated
           -- the PCS, tho.
           CompErrs pcs2
	      -> do let threaded2 = CmThreaded pcs2 hst1 hit1
                    return (threaded2, Nothing)

-- Remove unwanted modules from the top level envs (HST, HIT, UI).
removeFromTopLevelEnvs :: [ModuleName]
                       -> (HomeSymbolTable, HomeIfaceTable, UnlinkedImage)
                       -> (HomeSymbolTable, HomeIfaceTable, UnlinkedImage)
removeFromTopLevelEnvs zap_these (hst, hit, ui)
   = (delListFromUFM hst zap_these,
      delListFromUFM hit zap_these,
      filterModuleLinkables (`notElem` zap_these) ui
     )

retainInTopLevelEnvs :: [ModuleName]
                        -> (HomeSymbolTable, HomeIfaceTable)
                        -> (HomeSymbolTable, HomeIfaceTable)
retainInTopLevelEnvs keep_these (hst, hit)
   = (retainInUFM hst keep_these,
      retainInUFM hit keep_these
     )
     where
        retainInUFM :: Uniquable key => UniqFM elt -> [key] -> UniqFM elt
        retainInUFM ufm keys_to_keep
           = listToUFM (concatMap (maybeLookupUFM ufm) keys_to_keep)
        maybeLookupUFM ufm u 
           = case lookupUFM ufm u of Nothing -> []; Just val -> [(u, val)] 

-- Needed to clean up HIT and HST so that we don't get duplicates in inst env
downwards_closure_of_module :: [ModSummary] -> ModuleName -> [ModuleName]
downwards_closure_of_module summaries root
   = let toEdge :: ModSummary -> (ModuleName,[ModuleName])
         toEdge summ = (name_of_summary summ, ms_allimps summ)
         res = simple_transitive_closure (map toEdge summaries) [root]             
     in
         --trace (showSDoc (text "DC of mod" <+> ppr root
         --                 <+> text "=" <+> ppr res)) (
         res
         --)

-- Calculate transitive closures from a set of roots given an adjacency list
simple_transitive_closure :: Eq a => [(a,[a])] -> [a] -> [a]
simple_transitive_closure graph set 
   = let set2      = nub (concatMap dsts set ++ set)
         dsts node = fromMaybe [] (lookup node graph)
     in
         if   length set == length set2
         then set
         else simple_transitive_closure graph set2


-- Calculate SCCs of the module graph, with or without taking into
-- account source imports.
topological_sort :: Bool -> [ModSummary] -> [SCC ModSummary]
topological_sort include_source_imports summaries
   = let 
         toEdge :: ModSummary -> (ModSummary,ModuleName,[ModuleName])
         toEdge summ
             = (summ, name_of_summary summ, 
                      (if include_source_imports 
                       then ms_srcimps summ else []) ++ ms_imps summ)
        
         mash_edge :: (ModSummary,ModuleName,[ModuleName]) -> (ModSummary,Int,[Int])
         mash_edge (summ, m, m_imports)
            = case lookup m key_map of
                 Nothing -> panic "reverse_topological_sort"
                 Just mk -> (summ, mk, 
                                -- ignore imports not from the home package
                                catMaybes (map (flip lookup key_map) m_imports))

         edges     = map toEdge summaries
         key_map   = zip [nm | (s,nm,imps) <- edges] [1 ..] :: [(ModuleName,Int)]
         scc_input = map mash_edge edges
         sccs      = stronglyConnComp scc_input
     in
         sccs


-- Chase downwards from the specified root set, returning summaries
-- for all home modules encountered.  Only follow source-import
-- links.  Also returns a Bool to indicate whether any of the roots
-- are module Main.
downsweep :: [FilePath] -> [ModSummary] -> IO ([ModSummary], Bool)
downsweep rootNm old_summaries
   = do rootSummaries <- mapM getRootSummary rootNm
        let a_root_is_Main 
               = any ((=="Main").moduleNameUserString.name_of_summary) 
                     rootSummaries
        all_summaries
           <- loop (concat (map ms_imps rootSummaries))
		(filter (isHomeModule.ms_mod) rootSummaries)
        return (all_summaries, a_root_is_Main)
     where
	getRootSummary :: FilePath -> IO ModSummary
	getRootSummary file
	   | haskellish_file file
	   = do exists <- doesFileExist file
		if exists then summariseFile file else do
		throwDyn (OtherError ("can't find file `" ++ file ++ "'"))	
	   | otherwise
 	   = do exists <- doesFileExist hs_file
		if exists then summariseFile hs_file else do
		exists <- doesFileExist lhs_file
		if exists then summariseFile lhs_file else do
		getSummary (mkModuleName file)
           where 
		 hs_file = file ++ ".hs"
		 lhs_file = file ++ ".lhs"

        getSummary :: ModuleName -> IO ModSummary
        getSummary nm
           = do found <- findModule nm
		case found of
		   Just (mod, location) -> do
			let old_summary = findModInSummaries old_summaries mod
			new_summary <- summarise mod location old_summary
			case new_summary of
			   Nothing -> return (fromJust old_summary)
			   Just s  -> return s

		   Nothing -> throwDyn (OtherError 
                                   ("can't find module `" 
                                     ++ showSDoc (ppr nm) ++ "'"))
                                 
        -- loop invariant: home_summaries doesn't contain package modules
        loop :: [ModuleName] -> [ModSummary] -> IO [ModSummary]
	loop [] home_summaries = return home_summaries
        loop imps home_summaries
           = do -- all modules currently in homeSummaries
		let all_home = map (moduleName.ms_mod) home_summaries

		-- imports for modules we don't already have
                let needed_imps = nub (filter (`notElem` all_home) imps)

		-- summarise them
                needed_summaries <- mapM getSummary needed_imps

		-- get just the "home" modules
                let new_home_summaries
                       = filter (isHomeModule.ms_mod) needed_summaries

		-- loop, checking the new imports
		let new_imps = concat (map ms_imps new_home_summaries)
                loop new_imps (new_home_summaries ++ home_summaries)

-----------------------------------------------------------------------------
-- Summarising modules

-- We have two types of summarisation:
--
--    * Summarise a file.  This is used for the root module passed to
--	cmLoadModule.  The file is read, and used to determine the root
--	module name.  The module name may differ from the filename.
--
--    * Summarise a module.  We are given a module name, and must provide
--	a summary.  The finder is used to locate the file in which the module
--	resides.

summariseFile :: FilePath -> IO ModSummary
summariseFile file
   = do hspp_fn <- preprocess file
        modsrc <- readFile hspp_fn

        let (srcimps,imps,mod_name) = getImports modsrc
	    (path, basename, ext) = splitFilename3 file

	Just (mod, location)
	   <- mkHomeModuleLocn mod_name (path ++ '/':basename) file
	   
        maybe_src_timestamp
           <- case ml_hs_file location of 
                 Nothing     -> return Nothing
                 Just src_fn -> maybe_getModificationTime src_fn

        return (ModSummary mod
                           location{ml_hspp_file=Just hspp_fn}
                           srcimps imps
                           maybe_src_timestamp)

-- Summarise a module, and pick up source and timestamp.
summarise :: Module -> ModuleLocation -> Maybe ModSummary 
    -> IO (Maybe ModSummary)
summarise mod location old_summary
   | isHomeModule mod
   = do let hs_fn = unJust "summarise" (ml_hs_file location)

        maybe_src_timestamp
           <- case ml_hs_file location of 
                 Nothing     -> return Nothing
                 Just src_fn -> maybe_getModificationTime src_fn

	-- return the cached summary if the source didn't change
	case old_summary of {
	   Just s | ms_hs_date s == maybe_src_timestamp -> return Nothing;
	   _ -> do

        hspp_fn <- preprocess hs_fn
        modsrc <- readFile hspp_fn
        let (srcimps,imps,mod_name) = getImports modsrc

        maybe_src_timestamp
           <- case ml_hs_file location of 
                 Nothing     -> return Nothing
                 Just src_fn -> maybe_getModificationTime src_fn

	when (mod_name /= moduleName mod) $
		throwDyn (OtherError 
		   (showSDoc (text "file name does not match module name: "
			      <+> ppr (moduleName mod) <+> text "vs" 
			      <+> ppr mod_name)))

        return (Just (ModSummary mod location{ml_hspp_file=Just hspp_fn} 
                                 srcimps imps
                                 maybe_src_timestamp))
        }

   | otherwise
   = return (Just (ModSummary mod location [] [] Nothing))

maybe_getModificationTime :: FilePath -> IO (Maybe ClockTime)
maybe_getModificationTime fn
   = (do time <- getModificationTime fn
         return (Just time)) 
     `catch`
     (\err -> return Nothing)
\end{code}
