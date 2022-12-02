(** This file provide an common type for representing candidate executions
    for all memory models to use *)

(** TODO: document choices and caveats:
  - finite executions and relations
  - computable relations and allowedness
  - relation over event IDs, need to lookup candidate to get event content
 *)


Require Import Ensembles.

Require Import Strings.String.

From stdpp Require Export listset.
From stdpp Require Export gmap.

Require Import SSCCommon.Common.
Require Import SSCCommon.Exec.
Require Import SSCCommon.GRel.

Require Import ISASem.Interface.

Open Scope Z_scope.
Open Scope stdpp_scope.

Module CandidateExecutions (Arch : Arch) (IA : InterfaceT Arch). (* to be imported *)
  Import Arch.
  Import IA.
  Notation outcome := (IA.outcome empOutcome).
  Notation iMon := (IA.iMon empOutcome).
  Notation iSem := (IA.iSem empOutcome).
  Notation iEvent := (IA.iEvent empOutcome).
  Notation iTrace := (IA.iTrace empOutcome).

  (* event ID *)
  Module EID.
    Record t :=
      make {
          (* thread ID *)
          tid : nat;
          (* Instruction ID *)
          iid : nat;
          (* event number *)
          num : nat
          }.

    #[global] Instance eta : Settable _ :=
        settable! make <tid; iid; num>.

    #[global] Instance eq_dec : EqDecision t.
    Proof. solve_decision. Defined.

    #[global] Instance countable : Countable t.
    Proof.
      eapply (inj_countable' (fun eid => (tid eid, iid eid, num eid))
                        (fun x => make x.1.1 x.1.2 x.2)).
      sauto.
    Qed.
  End EID.

  Module Candidate.

    Record t :=
      make {
          (** Each thread is a list of instruction who each have a trace,
              we force the return type to be unit, but it just means we
              forget the actual value *)
          events : list (list (iTrace ()));
          (* TODO po can be deduced by the order of events in the trace *)
          (** Program order. The per-thread order of all events in the trace *)
          po : grel EID.t;
          (** Memory read from *)
          rf : grel EID.t;
          (** Memory coherence: for each pa, list of writes in order *)
          co : grel EID.t;
          (** Register read from (needed because of potentially relaxed register) *)
          rrf : grel EID.t;
          (* TODO can be deduced from trace structure *)
          (** Same instruction, should be an equivalence relation. *)
          si : grel EID.t;
          (** intra-instruction address dependencies (to memory events) *)
          iio_addr : grel EID.t;
          (** intra-instruction data dependencies (to memory and register writes) *)
          iio_data : grel EID.t;
          (** intra-instruction control dependencies (to branches) *)
          iio_ctrl : grel EID.t;
        }.

    (** Get an event at a given event ID in a candidate *)
    Global Instance lookup : Lookup EID.t iEvent t :=
      fun eid cd =>
        traces ← cd.(events) !! eid.(EID.tid);
        '(trace, result) ← traces !! eid.(EID.iid);
        trace !! eid.(EID.num).

    (** This true if one of the thread had an ISA model failure
        like a Sail assertion or an Isla assumption that failed *)
    Definition failed (cd : t) : bool :=
      existsb (fun traces =>
                 let '(trace, trace_end) := List.last traces ([], inl ()) in
                 match trace_end with | inr _ => true | inl _ => false end)
              cd.(events).

    Definition event_list (cd : t) : list (EID.t*iEvent) :=
      '(tid, traces) ← enumerate cd.(events);
      '(iid, (trace, trace_end)) ← enumerate traces;
       '(num, event) ← enumerate trace;
       [(EID.make tid iid num, event)].

    Definition event_map (cd : t) : gmap EID.t iEvent :=
          event_list cd |> list_to_map.

    Lemma event_map_match cd eid : cd !! eid = (event_map cd) !! eid.
    Admitted.

    (*** Accessors ***)

    Definition collect_all (P : iEvent -> bool) (cd : t) : gset EID.t :=
      filter (fun '(eid, event) => P event) (event_list cd)
        |> map fst |> list_to_set.

    (** Get the set of all valid EID for that candidate *)
    Definition valid_eid (cd : t) :=
      collect_all (fun event => true) cd.


    (** Get the set of all register reads *)
    Definition reg_reads (cd : t) :=
      collect_all
        (fun event =>
           match event with
           | IEvent (RegRead _ _) _ => true
           | _ => false end)
        cd.

    (** Get the set of all register writes *)
    Definition reg_writes (cd : t) :=
      collect_all
        (fun event =>
           match event with
           | IEvent (RegWrite _ _ _ _) _ => true
           | _ => false end)
        cd.

    (** Get the set of all memory reads *)
    Definition mem_reads (cd : t) :=
      collect_all
        (fun event =>
           match event with
           | IEvent (MemRead _ _) _ => true
           | _ => false end)
        cd.

    (** Get the set of all memory writes *)
    Definition mem_writes (cd : t) :=
      collect_all
        (fun event =>
           match event with
           | IEvent (MemWrite _ _) _ => true
           | _ => false end)
        cd.

    (** Get the set of all memory writes *)
    Definition mem_events (cd : t) :=
      collect_all
        (fun event =>
           match event with
           | IEvent (MemRead _ _) _ => true
           | IEvent (MemWrite _ _) _ => true
           | _ => false end)
        cd.

    (** Get the set of all barriers *)
    Definition branches (cd : t) :=
      collect_all
        (fun event =>
           match event with
           | IEvent (BranchAnnounce _ _) _ => true
           | _ => false end)
        cd.

    (** Get the set of all barriers *)
    Definition barriers (cd : t) :=
      collect_all
        (fun event =>
           match event with
           | IEvent (Barrier _) _ => true
           | _ => false end)
        cd.

    (** Get the content of a barrier, returns none if not a barrier (or is an
        invalid EID) *)
    Definition get_barrier (cd : t) (eid : EID.t) : option barrier:=
      match cd !! eid with
      | Some (IEvent (Barrier b) ()) => Some b
      | _ => None
      end.

    (** Get the set of all TLB operations *)
    Definition tlbops (cd : t) :=
      collect_all
        (fun event =>
           match event with
           | IEvent (TlbOp _) _ => true
           | _ => false end)
        cd.

    (** Get the content of a TLB operation, returns none if not a TLB operation
        (or is an invalid EID) *)
    Definition get_tlbop (cd : t) (eid : EID.t) : option tlb_op :=
      match cd !! eid with
      | Some (IEvent (TlbOp to) ()) => Some to
      | _ => None
      end.

    (*** Utility relations ***)

    (** Intra instruction order *)
    Definition iio (cd : t) := po cd ∩ si cd.

    Definition addr (cd : t) :=
      ⦗mem_reads cd⦘⨾
        (⦗mem_reads cd⦘ ∪ (iio_data cd ⨾ (rrf cd ∪ ⦗reg_writes cd⦘))⁺)⨾
        iio_addr cd⨾
        ⦗mem_events cd⦘.

    Definition data (cd : t) :=
      ⦗mem_reads cd⦘⨾
        (⦗mem_reads cd⦘ ∪ (iio_data cd ⨾ (rrf cd ∪ ⦗reg_writes cd⦘))⁺)⨾
        iio_data cd⨾
        ⦗mem_events cd⦘.

    Definition ctrl (cd : t) :=
      ⦗mem_reads cd⦘⨾
        (⦗mem_reads cd⦘ ∪ (iio_data cd ⨾ (rrf cd ∪ ⦗reg_writes cd⦘))⁺)⨾
        iio_ctrl cd⨾
        ⦗branches cd⦘⨾
        (po cd ∖ si cd).

    (** Symmetry relation referring to events having the same address.
        Might need to be updated for mixed-size *)
    Definition loc (cd : t) : grel EID.t :=
      let pa_map : gmap pa (gset EID.t) :=
        fold_left
        (fun pa_map '(eid, event) =>
           match event : iEvent with
           | IEvent (MemRead _ rr) _ => {[rr.(ReadReq.pa):= {[eid]}]} ∪ₘ pa_map
           | IEvent (MemWrite n rr) _ => {[rr.(WriteReq.pa):= {[eid]}]} ∪ₘ pa_map
           | _ => pa_map
           end) (event_list cd) ∅ in
      map_fold (fun (k : pa) (s : gset EID.t) (r : grel EID.t) => r ∪ (s × s))
        ∅ pa_map.




  End Candidate.

  (** Non-mixed size well-formedness *)
  Module NMSWF.
    Import Candidate.

    (** This relation only make sense for 8-bytes non-mixed-size models.
        It relates events with the same values *)
    Definition val (cd : t) : grel EID.t :=
      let val_map : gmap (bv 64) (gset EID.t) :=
        fold_left
        (fun val_map '(eid, event) =>
           match event : iEvent with
           | IEvent (MemRead 8 rr) (inl (val, _)) =>
               {[val := {[eid]}]} ∪ₘ val_map
           | IEvent (MemWrite 8 rr) _ =>
               {[rr.(WriteReq.value) := {[eid]}]} ∪ₘ val_map
           | _ => val_map
           end) (event_list cd) ∅ in
      map_fold (fun (k : bv 64) (s : gset EID.t) (r : grel EID.t) => r ∪ (s × s))
        ∅ val_map.

    Definition tlbops (cd : t) :=
      collect_all
        (fun event =>
           match event with
           | IEvent (TlbOp _) _ => true
           | _ => false end)
        cd.

    (** Check that all memory accesses have size 8. Alignment checking need to
        know how pa work and thus need to be architecture specific*)
    Definition size8_wf (cd : t) : bool :=
      collect_all
        (fun event =>
           match event with
           | IEvent (MemRead 8 _) _ => false
           | IEvent (MemRead _ _) _ => true
           | IEvent (MemWrite 8 _) _ => false
           | IEvent (MemWrite _ _) _ => true
           | _ => false
           end) cd =? ∅.

    Definition co_wf (cd : t) : bool :=
      let co := co cd in
      let loc := loc cd in
      let writes := mem_writes cd in
      grel_irreflexive co &&
        grel_transitive co &&
        bool_decide (co ⊆ loc) &&
        bool_decide (grel_dom co ⊆ writes) &&
        bool_decide (grel_rng co ⊆ writes) &&
        (loc ∩ (writes × writes) =? co ∪ co⁻¹ ∪ ⦗writes⦘).

    Definition rf_wf (cd : t) : bool :=
      let rf := rf cd in
      let loc := loc cd in
      let val := val cd in
      let reads := mem_reads cd in
      let writes := mem_writes cd in
      bool_decide (grel_dom rf ⊆ reads) &&
        bool_decide (grel_rng rf ⊆ writes) &&
        grel_functional (rf⁻¹) &&
        bool_decide (rf ⊆ loc ∩ val).
    (* TODO incomplete *)

    (* Definition last_reg_access : gmap reg EID.t. *)

    Module IIO.
      Record t :=
        make {
            last_reg_access : gmap reg EID.t;
            last_reg_read : list EID.t;
            last_mem_reads : list EID.t;
            iio_data : grel EID.t;
            iio_addr : grel EID.t;
            iio_ctrl : grel EID.t;
          }.

      #[global] Instance eta : Settable _ :=
        settable! make
        <last_reg_access; last_reg_read; last_mem_reads; iio_data; iio_addr; iio_ctrl>.

      Definition init := make ∅ ∅ ∅ ∅.

      Definition reset_thread := setv last_reg_access ∅.

      (* WIP *)

      (* Notation "'for' x 'in' l 'with' a 'do' E 'on' i 'end'" := *)
      (*   (fold_left (fun a x => E) l i) *)
      (*     (at level 200, i at level 100, x binder, right associativity, only parsing). *)


      (* Definition eval_DepOn (iio : t) (deps : DepOn.t) : gset EID.t := *)
      (*   match deps with *)
      (*   | None => list_to_set iio.(last_reg_read) ∪ *)
      (*              list_to_set iio.(last_mem_reads) *)


      (*   for reg in deps.(DepOn.regs) with res do *)
      (*     (option_to_set $ iio.(last_reg_access) !! reg) ∪ res *)
      (*   on *)
      (*     for read_num in deps.(DepOn.mem_reads) with res do *)
      (*       (option_to_set $ iio.(last_mem_reads) !! read_num) ∪ res *)
      (*     on ∅ end *)
      (*   end. *)

      (* Definition iio_recompute (cd : t) := *)
      (*   for '(tid, traces) in enumerate cd.(events) with iio do *)
      (*     for '(iid, (trace, trace_end)) in traces with iio do *)
      (*       for '(num, event) in trace with iio do *)
      (*         let eid := EID.make tid iid num in *)
      (*         match event with *)
      (*         | IEvent (RegRead reg _) _ => *)
      (*             set last_reg_access <[reg := num]> iio *)
      (*         | IEvent (RegWrite reg _ deps _) _ => *)
      (*             iio *)
      (*               |> set last_reg_access <[reg := num]> *)
      (*               |> set iio_data (.∪ eval_DepOn iio deps) *)
      (*         | IEvent (MemRead n rr) _ => *)
      (*             iio *)
      (*               |> set iio_addr (.∪ eval_DepOn iio rr.(ReadReq.addr_dep_on)) *)
      (*         end *)
      (*       on iio done *)
      (*     on iio done *)
      (*   on iio done. *)


      (*         let *)


      (*   fold_left (fun '(tid, traces) => *)
      (*     fold_left (fun '(iid, (trace, trace_end)) => *)
      (*       fold_left (fun '(num, event) iio => *)
      (*         let eid := EID.make tid iid num in *)
      (*         match event with *)
      (*         | IEvent (RegRead reg _) _ => *)
      (*             set last_reg_access <[reg := num]> iio *)
      (*         | IEvent (RegWrite reg _ deps) _ => *)
      (*             iio *)
      (*               |> set last_reg_access <[reg := num]> *)
      (*               |> set iio_data (.∪ eval_DepOn iio deps) *)
      (*         | IEvent (MemRead n rr) _ => *)
      (*             iio *)
      (*               |> set iio_addr (.∪ eval_DepOn iio rr.(ReadReq.addr_dep_on)) *)



      (*                       (<[reg:= num]> last_reg_access, iio_addr, iio_data, iio_ctrl) *)


      (*               ) trace *)
      (*          ) traces ∘ reset_thread *)
      (*     ) enumerate cd.(events) init *)



      (*     for '(num, event) in enumerate trace *)
      (*         with '(last_reg_access, iio_addr, iio_data, iio_ctrl) do *)








    (* Check that a candidate is self consistent *)
    (* Definition wf (cd : t) : bool := *)

    End IIO.


  End NMSWF.



End CandidateExecutions.
