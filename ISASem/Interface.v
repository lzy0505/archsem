
Require Import Strings.String.
Require Import bitvector.bitvector.

(* This is needed because sail cannot export into multiple Coq files *)
Require Import SailArmInst_types.

Local Open Scope stdpp_scope.
Local Open Scope Z_scope.

(** The architecture parameters that must be provided to the interface *)
Module Type Arch.

  (** The type of registers, most likely string, but may be more fancy *)
  Parameter reg : Type.

  (** The type of each register, often `bv 64` but it may be smaller or be a
      boolean *)
  Parameter reg_type : reg -> Type.

  (** Virtual address size *)
  Parameter va_size : N.

  (** Physical addresses type. Since models are expected to be architecture
      specific in this, there is no generic way to extract a bitvector from it*)
  Parameter pa : Type.

  (** Parameter for extra architecture specific access types. Can be set to
      False if not such types exists *)
  Parameter arch_ak : Type.

  (** Translation summary *)
  Parameter translation : Type.

  (** Abort description. This represent physical memory aborts on memory
      accesses, for example when trying to access outside of physical memory
      range. Those aborts are generated by the model*)
  Parameter abort : Type.

  (** Barrier types *)
  Parameter barrier : Type.

  (** Cache operations (data and instruction caches) *)
  Parameter cache_op : Type.

  (** TLB operation *)
  Parameter tlb_op : Type.

  (** Fault type for a fault raised by the instruction (not by the model) *)
  Parameter fault : Type.
End Arch.

Module Interface (A : Arch).

  Module DepOn.
    Record t :=
      make
        {
          (** The list of registers the effect depends on. *)
          regs : list A.reg;
          (** The list of memory access the effect depends on. The number
              corresponds to the memory reads done by the instruction in the
              order specified by the instruction semantics. The indexing starts
              at 0. *)
          mem_reads : list N
        }.
  End DepOn.

  Module ReadReq.
    Record t (n : N) :=
      make
        { pa : A.pa;
          access_kind : Access_kind A.arch_ak;
          va : option (bv A.va_size);
          translation : A.translation;
          tag : bool;
          (** The address dependency. If unspecified, it can be interpreted as
            depending on all previous registers and memory values that were read
            *)
          addr_dep_on : option DepOn.t;
        }.
  End ReadReq.

  Module WriteReq.
    Record t (n : N) :=
      make
        { pa : A.pa;
          access_kind : Access_kind A.arch_ak;
          value : bv (8 * n);
          va : option (bv A.va_size);
          translation : A.translation;
          tag : bool;
          (** The address dependency. If unspecified, it can be interpreted as
            depending on all previous registers and memory values that were read
            *)
          addr_dep_on : option DepOn.t;
          (** The data dependency. If unspecified, it can be interpreted as
            depending on all previous registers and memory values that were read
            *)
          data_dep_on : option DepOn.t;
        }.

  End WriteReq.

  Inductive outcome : Type -> Type :=
    (** The direct or indirect flag is to specify how much coherence is required
        for relaxed registers *)
  | RegRead (reg : A.reg) (direct : bool) : outcome (A.reg_type reg)

    (** The direct or indirect flag is to specify how much coherence is required
        for relaxed registers.

        The dep_on would be the dependency of the register write.

        Generally, writing the PC introduces no dependency because control
        dependencies are specified by the branch announce *)
  | RegWrite (reg : A.reg) (direct : bool) (dep_on : option DepOn.t)
    : A.reg_type reg -> outcome unit
  | MemRead (n : N) : ReadReq.t n ->
                      outcome (bv (8 * n) * option bool + A.abort)
  | MemWrite (n : N) : WriteReq.t n -> outcome (option bool + A.abort)
  | MemWriteAnnounce (n : N) : A.pa -> outcome unit
    (** The deps here specify the control dependency *)
  | BranchAnnounce (pa : A.pa) (dep_on : option DepOn.t) : outcome unit
  | Barrier : A.barrier -> outcome unit
  | CacheOp : A.cache_op -> outcome unit
  | TlbOp : A.tlb_op -> outcome unit
  | FaultAnnounce : A.fault -> outcome unit
  | EretAnnounce : outcome unit

  (** Bail out when something went wrong; this may be refined in the future *)
  | GenericFail (msg : string) : outcome False

  (** Terminate the instruction successfully *)
  | Success : outcome False

  (** The next two outcomes are for handling non-determinism. Choose will branch
      the possible executions non-deterministically for every bitvector of
      size n. *)
  | Choose (n : N) : outcome (bv n)
  (** Discard means that the instruction could never have made the previous
      non-deterministic choices and the current execution can be silently
      discarded. *)
  | Discard : outcome False.


  (********** Monad instance **********)

  (** This is a naive but inefficient implementation of the instruction monad.
      It might be replaced by an more efficient version later. *)
  Inductive iMon {a : Type} :=
  | Ret : a -> iMon
  | Next {T : Type} : outcome T -> (T -> iMon) -> iMon.
  Arguments iMon _ : clear implicits.

  Global Instance iMon_mret_inst : MRet iMon := { mret A := Ret }.

  Fixpoint iMon_bind {a b : Type} (ma : iMon a) (f : a -> iMon b) :=
    match ma with
    | Ret x => f x
    | Next oc k => Next oc (fun x => iMon_bind (k x) f) end.
  Global Instance iMon_mbind_inst : MBind iMon :=
    { mbind _ _ f x := iMon_bind x f}.

  Fixpoint iMon_fmap {a b : Type} (ma : iMon a) (f : a -> b) :=
    match ma with
    | Ret x => Ret (f x)
    | Next oc k => Next oc (fun x => iMon_fmap (k x) f)
    end.
  Global Instance iMon_fmap_inst : FMap iMon :=
    { fmap _ _  f x := iMon_fmap x f}.


  (********** Instruction semantics and traces **********)

  (** The semantics of an complete instruction. This is just a monad instance
  whose return type is false. This means that an instruction termination outcome
  is called in each possible branch. *)
  Definition iSem := iMon False.

  (** A single event in an instruction execution. As implied by the definition
      events cannot contain termination outcome (outcomes of type
      `outcome False`) *)
  Inductive event :=
  | Event {T : Type} : outcome T -> T -> event.

  (** An execution trace for a single instruction.
      If the option is None, it means a successful execution
      If the option is Some, it means a GenericFail *)
  Definition iTrace : Type := list event * option string.

  (** A trace is pure if it only contains external event. That means it much not
      contain control-flow event. The name "pure" is WIP.*)
  Fixpoint pure_iTrace_aux (tr : list event) : Prop :=
    match tr with
    | (Event (Choose _) _) :: _ => False
    | _ :: t => pure_iTrace_aux t
    | [] => True
    end.
  Definition pure_iTrace (tr : iTrace) :=
    let '(t,r) := tr in pure_iTrace_aux t.

  (** Definition of a trace semantics matching a trace. A trace is allowed to
      omit control-flow outcomes such as Choose and still be considered
      matching. *)
  Inductive iTrace_match : iSem -> iTrace -> Prop :=
  | TMNext T (oc : outcome T) (f : T -> iSem) (obj : T) rest e :
    iTrace_match (f obj) (rest, e) ->
    iTrace_match (Next oc f) ((Event oc obj) :: rest, e)
  | TMChoose n f (v : bv n) tr :
    iTrace_match (f v) tr -> iTrace_match (Next (Choose n) f) tr
  | TMSuccess f : iTrace_match (Next Success f) ([], None)
  | TMFailure f s : iTrace_match (Next (GenericFail s) f) ([], Some s).

  (** Semantic equivalence for instructions *)
  Definition iSem_equiv (i1 i2 : iSem) : Prop :=
    forall trace : iTrace,
    pure_iTrace trace -> (iTrace_match i1 trace <-> iTrace_match i2 trace).

End Interface.
