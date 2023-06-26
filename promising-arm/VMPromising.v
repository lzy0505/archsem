
Require Import Strings.String.
Require Import SSCCommon.Common.
Require Import SSCCommon.Exec.
Require Import SSCCommon.GRel.
Require Import Coq.Program.Equality.

From stdpp Require Import decidable.
From stdpp Require Import pretty.

Require UMPromising.

Require Import ISASem.ArmInst.
Require Import GenModels.TermModels.
Import UMPromising.TM.
Require Import GenPromising.
Import UMPromising.GP.

(** The goal of this module is to define an Virtual memory promising model,
    without mixed-size on top of the new interface *)

(** This model only works for 8-bytes aligned locations, as there
    in no support for mixed-sizes yet. Also all location are
    implicitly in the non-secure world.

    So in order to get the physical address you need to append 3 zeros.

    We reuse the location setup from the User-Mode promising model. *)
Module Loc := UMPromising.Loc.

(** Register and memory values (all memory access are 8 bytes aligned *)
Definition val := bv 64.

(** We also reuse the Msg object from the User-Mode Promising Model. *)
Module Msg := UMPromising.Msg.

Module TLBI.
  Inductive t :=
  | All (tid : nat)
  | Asid (tid : nat) (asid : bv 16)
  | Va (tid : nat) (asid : bv 16) (va : bv 36) (last : bool)
  | Vaa (tid : nat) (va : bv 36) (last : bool).

  #[global] Instance dec : EqDecision t.
  solve_decision.
  Defined.

  Definition tid (tlbi : t) : nat :=
    match tlbi with
    | All tid => tid
    | Asid tid _ => tid
    | Va tid _ _ _ => tid
    | Vaa tid _ _ => tid
    end.

  Definition asid_opt (tlbi : t) : option (bv 16) :=
    match tlbi with
    | All _ => None
    | Asid _ asid => Some asid
    | Va _ asid _ _ => Some asid
    | Vaa _ _ _ => None
    end.

  Definition asid (tlbi : t) : bv 16 :=
    default (Z_to_bv 16 0) (asid_opt tlbi).

  Definition va_opt (tlbi : t) : option (bv 36) :=
    match tlbi with
    | All _ => None
    | Asid _ _ => None
    | Va _ _ va _ => Some va
    | Vaa _ va _ => Some va
    end.

  Definition va (tlbi : t) : bv 36 :=
    default (Z_to_bv 36 0) (va_opt tlbi).

  Definition last_opt (tlbi : t) : option bool :=
    match tlbi with
    | All _ => None
    | Asid _ _ => None
    | Va _ _ _ last => Some last
    | Vaa _ _ last => Some last
    end.

  Definition last (tlbi : t) : bool :=
    default false (last_opt tlbi).
End TLBI.

(** Promising events appearing in the trace *)
Module Ev.
  Inductive t :=
  | Msg (msg : Msg.t)
  | Tlbi (tlbi : TLBI.t).

  #[global] Instance dec : EqDecision t.
  solve_decision.
  Defined.

  Definition tid (ev : t) :=
    match ev with
    | Msg msg => Msg.tid msg
    | Tlbi tlbi => TLBI.tid tlbi
    end.

  Definition is_write_to (loc : Loc.t) (ev : t) :=
    match ev with
    | Msg msg => Msg.loc msg =? loc
    | Tlbi _ => false
    end.
End Ev.
Coercion Ev.Msg : Msg.t >-> Ev.t.
Coercion Ev.Tlbi : TLBI.t >-> Ev.t.


(** A view is just a natural *)
Definition view := nat.
Bind Scope nat_scope with view.
Global Hint Transparent view : core.
Global Hint Unfold view : core.

Module Memory.
  Import PromMemory.

  (** Representation of initial memory, this is representation
      optimized for the internals of this model, so it not a plain
      memoryMap *)
  Definition initial := Loc.t -> val.

  (** Convert from a memoryMap to the internal representation: initial *)
  Definition initial_from_memMap (mem : memoryMap) : initial :=
    fun loc => Loc.to_pas loc |> map mem |> bv_of_bytes 8 64.

  (** The promising memory: a list of events *)
  Definition t : Type := t Ev.t.

  Definition cut_after : nat -> t -> t := @cut_after Ev.t.
  Definition cut_before : nat -> t -> t := @cut_before Ev.t.



 (** Reads the last write to a location in some memory. Gives the value and the
     timestamp of the write that it read from.
     The timestamp is 0 if reading from initial memory. *)
  Fixpoint read_last (loc : Loc.t) (init : initial) (mem : t) : (val * nat) :=
    match mem with
    | [] => (init loc, 0%nat)
    | (Ev.Msg msg) :: mem' =>
        if Msg.loc msg =? loc then
          (Msg.val msg, List.length mem)
        else read_last loc init mem'
    | Ev.Tlbi _ :: mem' => read_last loc init mem'
    end.

  (** Read memory at a given timestamp without any weak memory behaviour *)
  Definition read_at (loc : Loc.t) (init : initial) (mem : t) (time : nat) :=
    read_last loc init (cut_before time mem).

  (** Reads from initial memory and fail if the memory has been overwritten.

      This is mainly for instruction fetching in this model *)
  Definition read_initial (loc : Loc.t) (init : initial) (mem : t) : option val :=
    match read_last loc init mem with
    | (v, 0%nat) => Some v
    | _ => None
    end.

  (* (** Reads from initial memory for instruction fetch (only 4 bytes aligned) *)
  (*     and fail if the memory was modified *)
  (*  *) *)
  (* Definition read_ifetch (addr : bv 50) (init : initial) (mem : t) *)
  (*   : option val := *)
  (*   if existsb (fun ev => *)
  (*                 match ev with *)
  (*                 | Ev.Msg msg => Msg.lov msg =? (bv_extract 1 49 addr) *)
  (*                 | _ => false) mem *)
  (*   then None *)
  (*   else Some ( *)
  (*   match read_last loc init mem with *)
  (*   | (v, 0%nat) => Some v *)
  (*   | _ => None *)
  (*   end. *)



  (** To a snapshot of the memory back to a memoryMap *)
  Definition to_memMap (init : initial) (mem : t) : memoryMap:=
    fun pa =>
      (loc ← Loc.from_pa_in pa;
      let '(v, _) := read_last loc init mem in
      index ← Loc.pa_index pa;
      bv_to_bytes 8 v !! bv_unsigned index)
        |> default (bv_0 8).

  (** Adds the view number to each message given a view for the last message.
      This is for convenient use with cut_after.

      TODO: it would make sense to make a function that does cut_after
      and this in a single step. *)
  (* Fixpoint with_views_from (v : view) (mem : t) *)
  (*   : list (Msg.t * view) := *)
  (*   match mem with *)
  (*   | [] => [] *)
  (*   | h :: q => (v, h) :: with_views_from (v - 1) q *)
  (*   end. *)


  (** Returns the list of possible reads at a location restricted by a certain
      view. The list is never empty as one can always read from at least the
      initial value. *)
  Definition read (loc : Loc.t) (v : view) (init : initial) (mem : t)
    : list (val * view) :=
    let first := mem |> cut_before v |> read_last loc init in
    let lasts := mem |> cut_after_with_timestamps v
                     |> list_filter_map
                     (fun '(ev, v) =>
                        match ev with
                        | Ev.Msg msg =>
                            if Msg.loc msg =? loc
                            then Some (Msg.val msg, v)
                            else None
                        | Ev.Tlbi _ => None
                        end)
    in
    lasts ++ [first].

  (** Promise a write and add it at the end of memory *)
  Definition promise (ev : Ev.t) (mem : t) : view * t :=
    let nmem := ev :: mem in (List.length nmem, nmem).

  (** Returns a view among a promise set that correspond to an event. The
      oldest matching view is taken. This is because it can be proven that
      taking a more recent view, will make the previous promises unfulfillable
      and thus the corresponding executions would be discarded. TODO prove it.
      *)
  Definition fulfill (ev : Ev.t) (prom : list view) (mem : t) : option view :=
    prom |> filter (fun t => Some ev =? mem !! t)
         |> reverse
         |> head.

  (** Check that the write at the provided timestamp is indeed to that location
      and that no write to that location have been made by any other thread *)
  Definition exclusive (loc : Loc.t) (v : view) (mem : t) : bool:=
    match mem !! v with
    | Some (Ev.Msg msg) =>
        if Msg.loc msg =? loc then
          let tid := Msg.tid msg in
          mem |> cut_after v
              |> forallb
              (fun ev => match ev with
                      | Ev.Msg msg =>
                          (Msg.tid msg =? tid)
                          || negb (Msg.loc msg =? loc)
                      | _ => true
                      end)
        else false
    | _ => false
    end.

End Memory.

Module FwdItem.
   Record t :=
    make {
        time : nat;
        view : view;
        xcl : bool
      }.

   Definition init := make 0 0 false.
End FwdItem.


Definition EL := (fin 4).
Bind Scope fin_scope with EL.
Definition ELp := (fin 3).
Bind Scope fin_scope with ELp.

Definition ELp_to_EL : ELp -> EL := FS.



(** Any write to a register not explicitly supported by Reg.t will fail,
    because this means that the model doesn't know which behavior it is supposed to
    have *)
Module Reg.
  (** application/non-relaxed registers *)
  Inductive app :=
  | R (num : fin 31)
  | SP (el : EL)
  | PC
  | PSTATE.

  #[global] Instance app_dec : EqDecision app.
  solve_decision.
  Defined.

  Inductive sys :=
  | ELR (el : ELp)
  | FAR (el : ELp)
  | PAR (* EL1 *)
  | TTBR0 (el : ELp)
  | TTBR1_EL1
  | TTBR1_EL2
  | VBAR (el : ELp)
  | VTTBR (* EL2 *).

  #[global] Instance sys_dec : EqDecision sys.
  solve_decision.
  Defined.


  Inductive t :=
  | App (app : app)
  | Sys (sys : sys).

  #[global] Instance dec : EqDecision t.
  solve_decision.
  Defined.

  (* TODO generate that automatically? *)
  Definition from_arch (r : reg) :=
    match r with
    | "R0" => Some (App (R 0))
    | "R1" => Some (App (R 1))
    | "R2" => Some (App (R 2))
    | "R3" => Some (App (R 3))
    | "R4" => Some (App (R 4))
    | "R5" => Some (App (R 5))
    | "R6" => Some (App (R 6))
    | "R7" => Some (App (R 7))
    | "R8" => Some (App (R 8))
    | "R9" => Some (App (R 9))
    | "R10" => Some (App (R 10))
    | "R11" => Some (App (R 11))
    | "R12" => Some (App (R 12))
    | "R13" => Some (App (R 13))
    | "R14" => Some (App (R 14))
    | "R15" => Some (App (R 15))
    | "R16" => Some (App (R 16))
    | "R17" => Some (App (R 17))
    | "R18" => Some (App (R 18))
    | "R19" => Some (App (R 19))
    | "R20" => Some (App (R 20))
    | "R21" => Some (App (R 21))
    | "R22" => Some (App (R 22))
    | "R23" => Some (App (R 23))
    | "R24" => Some (App (R 24))
    | "R25" => Some (App (R 25))
    | "R26" => Some (App (R 26))
    | "R27" => Some (App (R 27))
    | "R28" => Some (App (R 28))
    | "R29" => Some (App (R 29))
    | "R30" => Some (App (R 30))
    | "SP_EL0" => Some (App (SP 0))
    | "SP_EL1" => Some (App (SP 1))
    | "SP_EL2" => Some (App (SP 2))
    | "SP_EL3" => Some (App (SP 3))
    | "PC_" => Some (App PC)
    | "PSTATE" => Some (App PSTATE)
    | "ELR_EL1" => Some (Sys (ELR 0))
    | "ELR_EL2" => Some (Sys (ELR 1))
    | "ELR_EL3" => Some (Sys (ELR 2))
    | "FAR_EL1" => Some (Sys (FAR 0))
    | "FAR_EL2" => Some (Sys (FAR 1))
    | "FAR_EL3" => Some (Sys (FAR 2))
    | "PAR_EL1" => Some (Sys PAR)
    | "TTBR0_EL1" => Some (Sys (TTBR0 0))
    | "TTBR0_EL2" => Some (Sys (TTBR0 1))
    | "TTBR0_EL3" => Some (Sys (TTBR0 2))
    | "TTBR1_EL1" => Some (Sys TTBR1_EL1)
    | "TTBR1_EL2" => Some (Sys TTBR1_EL2)
    | "VBAR_EL1" => Some (Sys (VBAR 0))
    | "VBAR_EL2" => Some (Sys (VBAR 1))
    | "VBAR_EL3" => Some (Sys (VBAR 2))
    | "VTTBR_EL2" => Some (Sys VTTBR)
    | _ => None
    end.

  Definition to_arch (reg : t) : Arm.reg :=
    match reg with
    | App (R n) => "R" ++ (pretty n)
    | App (SP n) => "SP_EL" ++ (pretty n)
    | App PC => "PC_"
    | App PSTATE => "PSTATE"
    | Sys (ELR n) => "ELR_EL" ++ (pretty (S n))
    | Sys (FAR n) => "FAR_EL" ++ (pretty (S n))
    | Sys PAR => "PAR_EL1"
    | Sys (TTBR0 n) => "TTBR0_EL" ++ (pretty (S n))
    | Sys TTBR1_EL1 => "TTBR1_EL1"
    | Sys TTBR1_EL2 => "TTBR1_EL2"
    | Sys (VBAR n) => "VBAR_EL" ++ (pretty (S n))
    | Sys VTTBR => "VTTBR_EL2"
    end.


  Ltac fin_case :=
    match goal with
    | n : fin 0 |- _ => dep_destruct n
    | n : fin _ |- _ => dep_destruct n; [| clear n]
    end.

  Lemma to_from_arch (reg : t) : from_arch (to_arch reg) = Some reg.
  Proof.
    destruct reg as [[]|[]];
      unfold EL,ELp in *;
      repeat (fin_case; [sfirstorder |]);
      try (fin_case);
      sfirstorder.
  Qed.

  Lemma from_to_arch (r : reg) (r' : t) : (from_arch r) = Some r' -> to_arch r' = r.
  Proof.
    intro H.
    unfold from_arch in H.
    repeat (discriminate H || case_split); inversion H; vm_compute; reflexivity.
  Qed.

End Reg.
Coercion Reg.App : Reg.app >-> Reg.t.
Coercion Reg.Sys : Reg.sys >-> Reg.t.

Module WSReg.
  Record t :=
    make {
        sreg : Reg.sys;
        val : regval;
        view : nat
      }.


  Definition to_val_view (wsreg : t) := (wsreg.(val), wsreg.(view)).
End WSReg.



(** The thread state *)
Module TState.
  Record t :=
    make {
        (* The promises that this thread must fullfil
           Is must be ordered with oldest promises at the bottom of the list *)
        prom : list view;

        (* registers values and views *)
        regs : Reg.app -> regval * view;
        regs_init : registerMap;
        sregs : list WSReg.t;

        (* The coherence views *)
        coh : Loc.t -> view;


        vrd : view; (* The maximum output view of a read  *)
        vwr : view; (* The maximum output view of a write  *)
        vdmbst : view; (* The maximum output view of a dmb st  *)
        vdmb : view; (* The maximum output view of a dmb ld or dmb sy  *)
        vdsb : view; (* The maximum output view of a dsb  *)
        vspec : view; (* The maximum output view of speculative operation. *)
        vcse : view; (* The maximum output view of an Context Synchronization Event *)
        vtlbi : view; (* The maximum output view of an TLBI *)
        vmsr : view; (* The maximum output view of an MSR *)
        vacq : view; (* The maximum output view of an acquire access *)
        vrel : view; (* The maximum output view of an release access *)

        (* Forwarding database. The first view is the timestamp of the
           write while the second view is the max view of the dependencies
           of the write. The boolean marks if the store was an exclusive*)
        fwdb : Loc.t -> FwdItem.t;

        (* Exclusive database. If there was a recent load exclusive but the
           corresponding store exclusive has not yet run, this will contain
           the timestamp and post-view of the load exclusive*)
        xclb : option (nat * view);

        (* Position in sregs of the last CSE event *)
        scse : nat;

        (* Recording of all previous updates of the MMU/TLB view of the system
           registers *)
        tlbscses : nat -> option nat
      }.

  #[global] Instance eta : Settable _ :=
    settable! make <prom;regs;regs_init;sregs;coh;vrd;vwr;vdmbst;vdmb;vdsb;
                    vspec;vcse;vtlbi;vmsr;vacq;vrel;fwdb;xclb;scse;tlbscses>.

  Definition init (mem : memoryMap) (iregs : registerMap) :=
    ({|
      prom := [];
      regs := fun reg => (iregs (Reg.to_arch reg), 0);
      regs_init := iregs;
      sregs := [];
      coh := fun loc => 0;
      vrd := 0;
      vwr := 0;
      vdmbst := 0;
      vdmb := 0;
      vdsb := 0;
      vspec := 0;
      vcse := 0;
      vtlbi := 0;
      vmsr := 0;
      vacq := 0;
      vrel := 0;
      fwdb := fun loc => FwdItem.init;
      xclb := None;
      scse := 0;
      tlbscses := (fun _ => None)
    |})%nat.

  Definition sreg_cur (ts : t) := length ts.(sregs).

  (** Read the last system register write at system register position s *)
  Definition read_sreg_last (ts : t) (s : nat) (sreg : Reg.sys) :=
    ts.(sregs)
         |> drop ((sreg_cur ts) - s)
         |> filter (fun wsreg => wsreg.(WSReg.sreg) = sreg)
         |> hd_error
         |> fmap (M:= option) WSReg.to_val_view
         |> default (ts.(regs_init) (Reg.to_arch sreg), 0%nat).

  (** Read all possible system register values for sreg assuming the last
      synchronization at position sync *)
  Definition read_sreg (ts : t) (sync : nat) (sreg : Reg.sys)
    : list (regval * view)
    :=
    let rest :=
      ts.(sregs)
           |> take ((sreg_cur ts) - sync)
           |> filter (fun wsreg => wsreg.(WSReg.sreg) = sreg)
           |> map WSReg.to_val_view
    in (read_sreg_last ts sync sreg) :: rest.

  (** Read uniformly a register of any kind. *)
  Definition read_reg (ts : t) (r : reg) : regval * view :=
    match Reg.from_arch r with
    | Some (Reg.App app) => ts.(regs) app
    | Some (Reg.Sys sys) => read_sreg_last ts (sreg_cur ts) sys
    | None => (ts.(regs_init) r, 0%nat)
    end.

  (** Extract a plain register map from the thread state without views.
      This is used to decide if a thread has terminated, and to observe the
      results of the model *)
  Definition reg_map (ts : t) : registerMap := fst ∘ read_reg ts.

  (** Sets the value of a register *)
  Definition set_reg (reg : Reg.app) (rv : reg_type * view) : t -> t
    := set regs (fun_add reg rv).

  (** Sets the coherence view of a location *)
  Definition set_coh (loc : Loc.t) (v : view) : t -> t :=
    set coh (fun_add loc v).

  (** Updates the coherence view of a location by taking the max of the new
      view and of the existing value *)
  Definition update_coh (loc : Loc.t) (v : view) (s : t) : t :=
    set_coh loc (max v (coh s loc)) s.

  (** Updates the forwarding database for a location. *)
  Definition set_fwdb (loc : Loc.t) (fi : FwdItem.t) : t -> t :=
    set fwdb (fun_add loc fi).

  (** Set the exclusive database to the timestamp and view of the latest
      load exclusive *)
  Definition set_xclb (vs : view * view) : t -> t :=
    set xclb (fun _ => Some vs).

  (** Clear the exclusive database, to mark a store exclusive *)
  Definition clear_xclb : t -> t :=
    set xclb (fun _ => None).

  (** Updates a view that from the state, by taking the max of new value and
      the current value.

      For example `update rmax vnew t` does t.rmax <- max t.rmax vnew *)
  Definition update (acc : t -> view) {_: Setter acc}
             (v : view) : t -> t :=
    set acc (max v).

  (** Updates two view in the same way as update. Purely for convenience *)
  Definition update2 (acc1 acc2 : t -> view) {_: Setter acc1} {_: Setter acc2}
             (v : view) : t -> t :=
    (update acc1 v) ∘ (update acc2 v).

  (** Add a promise to the promise set *)
  Definition promise (v : view) : t -> t := set prom (fun p => v :: p).

  (** Perform a context synchronization event *)
  Definition cse (v : view) (ts : t) : t :=
    ts |> setv scse (length ts.(sregs))
       |> update vcse v.

  (** Perform a flush of the last CSE to the MMU/TLB *)
  Definition tlbi_cse (v : view) (ts : t) : t :=
    set tlbscses (fun_add v (Some ts.(scse))) ts.
End TState.

(*** VA helper ***)

Definition Level := fin 4.

(* It is important to be consistent on "level_length" and not write it as 9 *
   lvl + 9, otherwise some term won't type because the equality is only
   propositional *)
Definition level_length (lvl : Level) : N := 9 * (lvl + 1).

Definition prefix (lvl : Level) := bv (level_length lvl).

Definition prefix_to_va {n : N} (p : bv n) : bv 64 :=
  bv_concat 64 (bv_0 16) (bv_concat 48 p (bv_0 (48 - n))).

Definition level_prefix {n : N} (va : bv n) (lvl : Level) : prefix lvl :=
  bv_extract (12 + 9 * (3 - lvl)) (9 * (lvl + 1)) va.

Definition level_index {n : N} (va : bv n) (lvl : Level) : bv 9 :=
  bv_extract 0 9 (level_prefix va lvl).

Definition higher_level {n : N} (va : bv n) : bv (n - 9) :=
  bv_extract 9 (n - 9) va.

Definition next_entry_loc (loc : Loc.t) (index : bv 9) : Loc.t :=
  bv_concat 49 (bv_extract 9 40 loc) index.

(*** TLB ***)

Lemma eqdec_existT `{EqDecision A} {P : A -> Type} (p : A) (x y : P p) :
  existT p x = existT p y <-> x = y.
  Proof. hauto q:on use: Eqdep_dec.inj_pair2_eq_dec. Qed.
#[global] Hint Rewrite @eqdec_existT using typeclasses eauto : core.



(* Set Printing Universes. *)

Class FinUnfold (n : nat) (p : fin n) (q : nat) := {fin_unfold : p =@{nat} q}.
Global Hint Mode FinUnfold + + - : typeclass_instances.

Global Instance fin_unfold_default (n : nat) (p : fin n) :
  FinUnfold n p p | 1000.
Proof. done. Qed.

Global Instance fin_unfold_F1 (n : nat) :
  FinUnfold (S n) 0 0.
Proof. done. Qed.

Global Instance fin_unfold_FS (n : nat) p q :
  FinUnfold n p q -> FinUnfold (S n) (FS p) (S q).
Proof. tcclean. done. Qed.

Lemma fin_cast_eq_refl {n : nat} (p : fin n) : Fin.cast p eq_refl = p.
Proof. induction p; sfirstorder. Qed.

Lemma fin_to_nat_cast {n m : nat} (p : fin n) (H : n = m) : Fin.cast p H =@{nat} p.
Proof.
  rewrite <- H.
  rewrite fin_cast_eq_refl.
  reflexivity.
Qed.

Global Instance fin_unfold_cast (n m : nat) (H : n = m) p q :
  FinUnfold n p q -> FinUnfold m (Fin.cast p H) q.
Proof. tcclean. by apply fin_to_nat_cast. Qed.

Lemma fin_to_nat_Fin_to_nat {n : nat} (p : fin n) : proj1_sig (Fin.to_nat p) =@{nat} p.
Proof. induction p; hauto lq:on. Qed.

Global Instance fin_unfold_L (n m : nat) p q :
  FinUnfold n p q -> FinUnfold (n + m) (Fin.L m p) q.
Proof.
  tcclean.
  setoid_rewrite <- fin_to_nat_Fin_to_nat.
  apply Fin.L_sanity.
Qed.

Global Instance fin_unfold_R (n m : nat) p q :
  FinUnfold n p q -> FinUnfold (m + n) (Fin.R m p) (m + q).
Proof.
  tcclean.
  setoid_rewrite <- fin_to_nat_Fin_to_nat.
  apply Fin.R_sanity.
Qed.

Global Instance fin_unfold_nat_to_fin (n p : nat) (H : (p < n)%nat) :
  FinUnfold n (nat_to_fin H) p.
Proof. tcclean. by rewrite fin_to_nat_to_fin. Qed.

Program Definition fin_L1 {n : nat} (p : fin n) : fin (S n) :=
  Fin.cast (Fin.L 1 p) _.
Solve All Obligations with lia.

Global Instance fin_unfold_L1 (n : nat) p q :
  FinUnfold n p q -> FinUnfold (S n) (fin_L1 p) q.
Proof.
  tcclean.
  by rewrite fin_unfold.
Qed.

Opaque fin_L1.




Program Definition FS_fin_L1 {n : nat} (p : fin n) : FS (fin_L1 p) = fin_L1 (FS p).
Proof.
  apply (inj fin_to_nat).
  setoid_rewrite fin_unfold.
  reflexivity.
Qed.

Program Definition fin_last (n : nat) : fin (S n) :=
  nat_to_fin (_ : n < S n)%nat.
Next Obligation.
  lia.
Defined.

Global Instance fin_unfold_last (n : nat) :
  FinUnfold (S n) (fin_last n) n.
Proof.
  tcclean.
  by rewrite fin_unfold.
Qed.

Opaque fin_last.

Lemma FS_fin_last (n : nat) : FS (fin_last n) = fin_last (S n).
Proof.
  apply (inj fin_to_nat).
  setoid_rewrite fin_unfold.
  reflexivity.
Qed.

Definition fin_last_inv {n} (P : fin (S n) → Type)
  (Hend : P (fin_last n)) (HS : ∀ (i : fin n), P (fin_L1 i)) (i : fin (S n)) : P i.
Proof.
  induction n.
  - inv_fin i.
    + apply Hend.
    + intro i2. inv_fin i2.
  - inv_fin i.
    + pose (H := HS 0%fin).
      apply H.
    + apply IHn.
      * rewrite FS_fin_last.
        apply Hend.
      * intro i.
        rewrite FS_fin_L1.
        apply HS.
Defined.

Program Definition fin_upcast {n m : nat} (H : (n <= m)%nat) (p : fin n) : fin m :=
  nat_to_fin (_ : (p < m) %nat).
Next Obligation.
  intros.
  use (fin_to_nat_lt p).
  lia.
Qed.

Global Instance fin_unfold_fin_upcast (n p : nat) (H : (p <= n)%nat) (i : fin p) q :
  FinUnfold p i q ->
  FinUnfold n (fin_upcast H i) q.
Proof.
  tcclean.
  unfold fin_upcast.
  rewrite fin_unfold.
  reflexivity.
Qed.
Opaque fin_upcast.



Fixpoint hvec (n : nat) : (fin n -> Type) -> Type :=
  match n with
  | 0%nat => fun _ => unit
  | S m => fun T => ((T 0%fin) * hvec m (T ∘ FS))%type
  end.
Arguments hvec {n} T.

Fixpoint hget {n : nat} (i : fin n) : forall T : fin n -> Type, hvec T -> T i :=
  match i with
  | 0%fin => fun _ v => v.1
  | FS p => fun _ v => hget p _ v.2
  end.
Arguments hget {n} i {T} v.

Fixpoint hvec_func {n : nat} : forall T : fin n -> Type, (forall i, T i) -> hvec T :=
  match n with
  | 0%nat => fun _ f => ()
  | S m => fun _ f => (f 0%fin, hvec_func _ (fun x => f (FS x)))
  end.
Arguments hvec_func {n T} f.

Fixpoint hset {n : nat} (i : fin n) : forall T : fin n -> Type, T i -> hvec T -> hvec T :=
  match i with
  | 0%fin => fun _ nv v => (nv, v.2)
  | FS p => fun _ nv v => (v.1, hset p _ nv v.2)
  end.
Arguments hset {n} i {T} nv v.

Lemma hvec_get_func {n : nat} {T : fin n -> Type} (i : fin n) (f : forall i, T i) :
  hget i (hvec_func f) = f i.
Proof. induction i; hauto. Qed.

Lemma hvec_get_set_same {n : nat} {T : fin n -> Type}
  (v : hvec T) (i : fin n) (nv : T i) :
  hget i (hset i nv v) = nv.
Proof. induction i; hauto. Qed.

Lemma hvec_get_set_diff {n : nat} {T : fin n -> Type}
  (v : hvec T) (i j : fin n) (nv : T j) :
  i ≠ j -> hget i (hset j nv v) = hget i v.
Proof. induction i; sauto dep:on. Qed.

(* Technically, this is mapi, but a plain map can't exist because of dependent
 typing *)
Definition hmap {n : nat} {T1 T2 : fin n -> Type} (f : forall i, T1 i -> T2 i)
  (v : hvec T1) : hvec T2 := hvec_func (fun i => f i (hget i v)).

Definition hmap2 {n : nat} {T1 T2 T3 : fin n -> Type} (f : forall i, T1 i -> T2 i -> T3 i)
  (v1 : hvec T1) (v2 : hvec T2) : hvec T3
  := hvec_func (fun i => f i (hget i v1) (hget i v2)).

Lemma hget_hmap {n : nat} {T1 T2 : fin n -> Type} (f : forall i, T1 i -> T2 i)
  (v : hvec T1) (i : fin n) :
  hget i (hmap f v) = f i (hget i v).
Proof.
  unfold hmap.
  rewrite hvec_get_func.
  reflexivity.
Qed.

Definition hlast {n : nat} {T : fin (S n) -> Type} (v : hvec T) : T (fin_last n)
  := hget (fin_last n) v.







Global Instance sigT_dec `{EqDecision A} (P : A -> Type)
  `{forall a: A, EqDecision (P a)} : EqDecision (sigT P).
  unfold EqDecision.
  intros [x p] [y q].
  destruct (decide (x = y)) as [e | e].
  - destruct e.
    destruct (decide (p = q)) as [e | e].
    + destruct e.
      left.
      reflexivity.
    + right.
      intro.
      apply e.
      apply eqdec_existT.
      assumption.
  - right.
    intro.
    apply e.
    eapply eq_sigT_fst.
    eassumption.
Defined.

Unset Program Cases.

Global Program Instance countable_sigT `{Countable A} (P : A -> Type)
  {eqP : forall a : A, EqDecision (P a)} {cntP: forall a : A, Countable (P a)}
  : Countable (sigT P) :=
  (inj_countable (fun sig => (projT1 sig, encode (projT2 sig)))
                        (fun '(a, b) =>
                           bd ← decode b;
                           Some $ existT a bd) _).
Next Obligation.
  intros.
  cbn.
  setoid_rewrite decode_encode.
  hauto lq:on.
Qed.

Module TLB.

  Module NDCtxt.
    Record t (lvl : Level) :=
      make
        {
          va : prefix lvl;
          asid : option (bv 16);
        }.
    Arguments make {_} _ _.
    Arguments va {_}.
    Arguments asid {_}.

    #[global] Instance dec lvl : EqDecision (t lvl).
    Proof. solve_decision. Defined.

    #[global] Instance count lvl : Countable (t lvl).
    Proof.
      eapply (inj_countable' (fun ndc => (va ndc, asid ndc))
                        (fun x => make x.1 x.2)).
      sauto.
    Qed.

    (* unfold EqDecision. *)
    (* intros [lvlx vax asidx] [lvly vay asidy]. *)
    (* destruct (decide (lvlx = lvly)) as [<- | H]. *)
    (* destruct (decide (vax = vay)) as [<- | H]. *)
    (* destruct (decide (asidx = asidy)) as [<- | H]. *)
    (* left. reflexivity. *)
    (* all :right; inversion 1; autorewrite with core in *; done. *)
    (* Defined. *)
  End NDCtxt.

  Module Ctxt.
    Definition t := {lvl : Level & NDCtxt.t lvl}.
    Definition lvl : t -> Level := projT1.
    Definition nd (ctxt : t) : NDCtxt.t (lvl ctxt) := projT2 ctxt.
    Definition va (ctxt : t) : prefix (lvl ctxt) := NDCtxt.va (nd ctxt).
    Definition asid (ctxt : t) : option (bv 16) := NDCtxt.asid (nd ctxt).
    (* #[global] Instance dec : EqDecision t. *)
    (* Proof. solve_decision. Defined. *)
  End Ctxt.

  Module Entry.
    Definition t (lvl : Level) := vec val (S lvl).
    Definition pte {lvl} (tlbe : t lvl) := Vector.last tlbe.
    #[global] Instance dec lvl : EqDecision (t lvl).
    Proof. solve_decision. Defined.
  End Entry.

  (* Full Entry *)
  Module FE.
    Definition t := { ctxt : Ctxt.t & Entry.t (Ctxt.lvl ctxt) }.
    #[global] Instance dec : EqDecision t.
    Proof. solve_decision. Defined.
  End FE.

  Module VATLB.
    Definition T (lvl : Level) := gmap (NDCtxt.t lvl) (gset (Entry.t lvl)).
    Definition t := hvec T.

    Definition init : t := hvec_func (fun lvl => ∅).

    Definition get (ctxt : Ctxt.t) (vatlb : t)
      : gset (Entry.t (Ctxt.lvl ctxt)) :=
      (hget (Ctxt.lvl ctxt) vatlb) !! (Ctxt.nd ctxt) |> default ∅.

    Definition getFE (ctxt : Ctxt.t) (vatlb : t)
      : gset (FE.t) :=
      get ctxt vatlb
      |> set_map (fun (e : Entry.t (Ctxt.lvl ctxt)) => existT ctxt e).

    #[global] Instance union : Union t := fun x y => hmap2 (fun _ => (∪ₘ)) x y.
  End VATLB.

  Record t :=
    make {
        scse : nat;
        vatlb : VATLB.t
      }.

  Definition init := make 0 VATLB.init.

  Definition read_sreg (tlb : t) (ts : TState.t) (time : nat)
    (sreg : Reg.sys) :=
    TState.read_sreg ts tlb.(scse) sreg
    |> filter (fun '(val, v) => v <= time)%nat.



  (* Program Definition va_fill_lvl0 (tlb : t) (ts : TState.t) *)
  (*   (init : Memory.initial) *)
  (*   (mem : Memory.t) (time : nat) : VATLB.t := *)
  (*   tlb.(vatlb) ∪ *)
  (*     fun ctxt => *)
  (*       match ctxt.(Ctxt.lvl) with *)
  (*       | 0%fin => *)
  (*           match ctxt.(Ctxt.asid) return gset (Entry.t ctxt.(Ctxt.lvl)) with *)
  (*           | Some asid => *)
  (*               ( *)
  (*                 let valttbrs := *)
  (*                   (* read_sreg tlb ts time (Reg.TTBR0 0%fin) *) *)
  (*                   (* |> List.filter (fun '(val,v) => bv_extract 48 16 val =? asid) *) *)
  (*                   [] *)
  (*                 in *)
  (*                 valttbr ← valttbrs; *)
  (*                 let root_addr := *)
  (*                   bv_concat 64 (bv_0 16) (bv_extract 0 48 valttbr) in *)
  (*                 root_loc ← Loc.from_va root_addr |> option_list; *)
  (*                 let loc := next_entry_loc root_loc ctxt.(Ctxt.va) in *)
  (*                 let '(val, _) := Memory.read_at loc init mem time in *)
  (*                 [Vector.const val 1] *)
  (*               ) *)
  (*                |> list_to_set *)
  (*           | None => ∅ *)
  (*           end *)
  (*       | _ => ∅ *)
  (*       end. *)





  (** WARNING HACK: Coq is shit so I'm forced to copy paste this function 3
      times, because after 4 hours I didn't find a way to make it type a generic
      version (among various internal crashes and similar errors). *)

  (** Needed to do sensible match case on fin values *)
  Definition fin_case {n : nat} (i : fin (S n)) : option (fin n) :=
    match i with
    | Fin.F1 => None
    | FS n => Some n
    end.

  (* TODO report bug: Function is incompatible with Keyed Unification *)
  #[local] Unset Keyed Unification.

  Fixpoint fin_inj1 {n : nat} (p : fin n) : fin (S n) :=
    match p with
    | Fin.F1 => Fin.F1
    | FS p' => FS (fin_inj1 p')
    end.


  Lemma fin_to_nat_fin_inj1 {n : nat} (p : fin n) : fin_inj1 p =@{nat} p.
    Admitted.

  (* Lemma va_fill_termination {n : nat} (i : fin (S n)) (j : fin n) : *)
  (*   fin_case i = Some j -> (Fin.L 1 j < i)%nat. *)
  (*   inv_fin i. *)

  Set Printing Implicit.
  Set Printing Coercions.

  (* Function va_fill_lvl (tlb : t) (ts : TState.t) *)
  (*   (init : Memory.initial) *)
  (*   (mem : Memory.t) (time : nat) (lvl : Level) {measure fin_to_nat lvl } := *)
  (*   match fin_case lvl return VATLB.t with *)
  (*   | None => VATLB.init *)
  (*   | Some n => *)
  (*       va_fill_lvl tlb ts init mem time (fin_inj1 n) *)
  (*   end *)
  (*   ∪ tlb.(vatlb). *)
  (* Proof. *)
  (*   intros. *)
  (*   inv_fin lvl. *)
  (*   scongruence. *)
  (*   cbn in *. *)
  (*   intros. *)
  (*   inversion teq as []. *)
  (*   destruct H. *)
  (*   rewrite fin_to_nat_fin_inj1. *)
  (*   lia. *)
  (* Qed. *)



  (* Program Fixpoint va_fill_lvl (lvl : Level) {measure (fin_to_nat lvl) } := *)
  (*   fun (tlb : t) (ts : TState.t) *)
  (*   (init : Memory.initial) *)
  (*   (mem : Memory.t) (time : nat) => *)
  (*   match lvl return VATLB.t with *)
  (*   | Fin.F1 => VATLB.init *)
  (*   | FS n => va_fill_lvl (n : Level) tlb ts init mem time *)
  (*   end. *)
  (* Next Obligation. *)
  (*   intros. *)
  (* Admitted. *)
  (* Next Obligation. *)
  (* Admitted. *)
  (* Next Obligation. *)
  (* Admitted. *)

  (* Print va_fill_lvl. *)


  (* Definition va_fill (tlb : t) (ts : TState.t) (init : Memory.initial) *)
  (*   (mem : Memory.t) (time : nat) : VATLB.t. *)
  (* Admitted. *)


  (** Get the TLB state at a certain timestamp *)
  (* Definition get (ts : TState.t) (init : Memory.initial) (mem : Memory.t) *)
  (*               (time : nat) : t. *)
End TLB.

Module VATLB := TLB.VATLB.



(*** Instruction semantics ***)

(** Intra instruction state for propagating views inside an instruction *)
Module IIS.

  (* Translation Results *)
  Module TransRes.
    Record t :=
      make {
          time : nat;
          remaining : list (bv 64);
          invalidation : nat
        }.

    #[global] Instance eta : Settable _ :=
      settable! make <time; remaining; invalidation>.

    Definition pop (tr : t) : Exec.t string (bv 64 * t) :=
      match tr.(remaining) with
      | h :: tl => Exec.ret (h, setv remaining tl tr)
      | _ => Exec.Error
              "Couldn't pop the next PTE: error in translation assumptions"
      end.
  End TransRes.

  Record t :=
    make {
        regs : view; (* All the register reads that happened before *)
        nreg : view;(* All the previous non-register events *)
        reads : list view; (* The post view of all the reads *)
        (* The translations whose results were already selected *)
        trs : bv 36 -> option TransRes.t
      }.

  #[global] Instance eta : Settable _ :=
    settable! make <regs;nreg;reads; trs>.

  Definition init : t := make 0 0 [] (fun _ => None).

  (** Add a new memory read to the IIS *)
  Definition add_read (v : view) (iis : t) : t :=
    iis |> set nreg (max v)
        |> set reads (.++ [v]).

  (** Add a new non-register event to the IIS *)
  Definition add_nreg (v : view) (iis : t) : t :=
    iis |> set nreg (max v).

  (** Add a new register read to the IIS *)
  Definition add_reg (v : view) (iis : t) : t :=
    iis |> set regs (max v).

  Definition from_read_deps (deps : list nat) (iis : t) : view :=
   List.fold_left (fun v dep => match iis.(reads) !! dep with
                                  | Some v' => max v v'
                                  | None => v end) deps 0%nat.

  Definition from_DepOn (deps : DepOn.t) (ts : TState.t) (iis : t)
    : view :=
    max (from_read_deps deps.(DepOn.mem_reads) iis) $
    List.fold_left (fun v reg => max v $ snd $ TState.read_reg ts reg)
                   deps.(DepOn.regs) 0%nat.

  Definition from_DepOn_opt (deps : option DepOn.t) regsm iis :=
    match deps with
    | None => iis.(regs) ⊔ list_max iis.(reads)
    | Some deps => from_DepOn deps regsm iis
    end.

  Definition set_trs (va : bv 36) (tres : TransRes.t) :=
    set trs (fun_add va (Some tres)).

End IIS.


Definition view_if (b : bool) (v : view) := if b then v else 0%nat.

(** The view of a read from a forwarded write *)
Definition read_fwd_view (ak : Explicit_access_kind) (f : FwdItem.t) :=
  if f.(FwdItem.xcl) && negb (ak.(Explicit_access_kind_strength) =? AS_normal)
  then f.(FwdItem.time) else f.(FwdItem.view).



(** Performs a memory read at a location with a view and return possible output
    states with the timestamp and value of the read *)
Definition read_mem_explicit (loc : Loc.t) (vaddr : view) (viio : view)
  (invalidation_time : nat) (ak : Explicit_access_kind) (ts : TState.t)
  (init : Memory.initial) (mem : Memory.t)
  : Exec.t string (TState.t * view * val) :=
  let acs := ak.(Explicit_access_kind_strength) in
  let acv := ak.(Explicit_access_kind_variety) in
  Exec.fail_if (acv =? AV_atomic_rmw) "Atomic RMV unsupported";;
  let vbob := ts.(TState.vdmb) ⊔ ts.(TState.vdsb)
              ⊔ ts.(TState.vcse) ⊔ ts.(TState.vacq)
                (* Strong Acquire loads are ordered after Release stores *)
              ⊔ view_if (acs =? AS_rel_or_acq) ts.(TState.vrel) in
  let vpre := vaddr ⊔ vbob ⊔ viio in
  (* We only read after the coherence point, because without mixed-size, this
     is equivalent to reading at vpre and discarding incoherent options *)
  let vread := vpre ⊔ (TState.coh ts loc) in
  '(res, time) ← Exec.Results $ Memory.read loc vread init mem;
  let fwd := TState.fwdb ts loc in
  let read_view :=
    if (fwd.(FwdItem.time) =? time) then read_fwd_view ak fwd else time in
  let vpost := vpre ⊔ read_view in
  Exec.assert (vpost <=? invalidation_time)%nat;;
  let ts :=
    ts |> TState.update_coh loc time
       |> TState.update TState.vrd vpost
       |> TState.update TState.vacq (view_if (negb (acs =? AS_normal)) vpost)
       |> TState.update TState.vspec vaddr
       |> (if acv =? AV_exclusive then TState.set_xclb (time, vpost) else id)
  in Exec.ret (ts, vpost, res).

Definition read_pte (ts : TState.t) (vaddr : view) (viio : view)
  (tsum : translation) (tres : IIS.TransRes.t)
  : Exec.t string (TState.t * view * val * IIS.TransRes.t) :=
  let vpost := vaddr ⊔ viio ⊔ tres.(IIS.TransRes.time) in
  '(val, tres) ← IIS.TransRes.pop tres;
  let ts := ts |> TState.update TState.vspec vpost in
  Exec.ret (ts, vpost, val, tres).




(** Run a MemRead outcome.
    Returns the new thread state, the vpost of the read and the read value. *)
Definition run_mem_read (rr : ReadReq.t DepOn.t 8) (iis : IIS.t)
  (ts : TState.t) (init : Memory.initial) (mem : Memory.t)
  : Exec.t string (TState.t * IIS.t * val) :=
  addr ← Exec.error_none "PA not supported" $ Loc.from_pa rr.(ReadReq.pa);
  let vaddr :=
    IIS.from_DepOn rr.(ReadReq.addr_deps) ts iis
  in
  let va : bv 64 := default (Loc.to_va addr) rr.(ReadReq.va) in
  let trans_res := iis.(IIS.trs) (bv_extract 12 36 va) in
  let inv :=
    trans_res |> fmap (fun tr => tr.(IIS.TransRes.invalidation)) |> default (0 % nat)
  in
  let viio := IIS.nreg iis in
  match rr.(ReadReq.access_kind) with
  | AK_explicit eak =>
      '(ts, view, val) ← read_mem_explicit addr vaddr viio inv eak ts init mem;
      let iis := IIS.add_read view iis in
      Exec.ret (ts, iis, val)
  | AK_ttw () =>
      tres ← Exec.error_none "TTW read before translation start" trans_res;
      '(ts, view, val, tres) ←
        read_pte ts vaddr viio rr.(ReadReq.translation) tres;
      let iis :=
        iis |> IIS.add_read view
          |> IIS.set_trs (bv_extract 12 36 va) tres
      in Exec.ret (ts, iis, val)
  | AK_ifetch () => Exec.Error "8 bytes ifetch ???"
  | _ => Exec.Error "Only ifetch, ttw and explicit accesses supported"
  end.


Definition run_mem_read4 (rr : ReadReq.t DepOn.t 4) (iis : IIS.t)
  (ts : TState.t) (init : Memory.initial) (mem : Memory.t)
  : Exec.t string (bv 32) :=
  let addr := rr.(ReadReq.pa) in
  let aligned_addr := set FullAddress_address (bv_unset_bit 2) addr in
  let bit2 := addr.(FullAddress_address) |> bv_get_bit 2 in
  loc ← Exec.error_none "PA not supported" $ Loc.from_pa aligned_addr;
  match rr.(ReadReq.access_kind) with
  | AK_ifetch () =>
      block ← Exec.error_none "Modified instruction memory"
                              (Memory.read_initial loc init mem);
      (if bit2 then bv_extract 32 32 else bv_extract 0 32) block
        |> Exec.ret
  | _ => Exec.Error "4 bytes accesses unsupported (except ifetch)"
  end.



(** Performs a memory write for a thread tid at a location loc with view
    vaddr and vdata. Return the new state.

    This may mutate memory if no existing promise can be fullfilled *)
Definition write_mem (tid : nat) (loc : Loc.t) (vaddr : view) (vdata : view)
           (viio : view)
           (acs : Access_strength) (ts : TState.t) (mem : Memory.t)
           (data : val) : Exec.t string (TState.t * Memory.t * view):=
  let msg := Msg.make tid loc data in
  let is_release := acs =? AS_rel_or_acq in
  let '(time, mem) :=
    match Memory.fulfill msg (TState.prom ts) mem with
    | Some t => (t, mem)
    | None => Memory.promise msg mem
    end in
  let vbob :=
    ts.(TState.vdmbst) ⊔ ts.(TState.vdmb) ⊔ ts.(TState.vdsb)
    ⊔ ts.(TState.vcse) ⊔ ts.(TState.vacq)
    ⊔ view_if is_release (ts.(TState.vrd) ⊔ ts.(TState.vwr)) in
  let vpre := vaddr ⊔ vdata ⊔ ts.(TState.vspec) ⊔ vbob ⊔ viio in
  Exec.assert (vpre ⊔ (TState.coh ts loc) <? time)%nat;;
  let ts :=
    ts |> set TState.prom (delete time)
       |> TState.update_coh loc time
       |> TState.update TState.vwr time
       |> TState.update TState.vrel (view_if is_release time)
       |> TState.update TState.vspec vaddr
  in Exec.ret (ts, mem, time).


(** Tries to perform a memory write.

    If the store is not exclusive, the write is always performed and the third
    return value is true.

    If the store is exclusive the write may succeed or fail and the third
    return value indicate the success (true for success, false for error) *)
Definition write_mem_xcl (tid : nat) (loc : Loc.t) (vaddr : view)
           (vdata : view) (viio : view) (ak : Explicit_access_kind)
           (ts : TState.t) (mem : Memory.t) (data : val)
  : Exec.t string (TState.t * Memory.t):=
  let acs := Explicit_access_kind_strength ak in
  let acv := Explicit_access_kind_variety ak in
  Exec.fail_if (acv =? AV_atomic_rmw) "Atomic RMV unsupported";;
  let xcl := acv =? AV_exclusive in
  if xcl then
    '(ts, mem, time) ← write_mem tid loc vaddr vdata viio acs ts mem data;
    match TState.xclb ts with
    | None => Exec.discard
    | Some (xtime, xview) =>
        Exec.assert $ Memory.exclusive loc xtime (Memory.cut_after time mem)
    end;;
    let ts := TState.set_fwdb loc (FwdItem.make time (vaddr ⊔ vdata) true) ts in
    Exec.ret (TState.clear_xclb ts, mem)
  else
    '(ts, mem, time) ← write_mem tid loc vaddr vdata viio acs ts mem data;
    let ts := TState.set_fwdb loc (FwdItem.make time (vaddr ⊔ vdata) false) ts in
    Exec.ret (ts, mem).

Definition run_cse (iis : IIS.t) (ts : TState.t) : IIS.t * TState.t :=
  let vpost :=
    ts.(TState.vspec) ⊔ ts.(TState.vcse)
    ⊔ ts.(TState.vdsb) ⊔ ts.(TState.vmsr)
  in
  (IIS.add_nreg vpost iis, TState.cse vpost ts).

(** Perform a barrier, mostly view shuffling *)
Definition run_barrier (iis : IIS.t) (ts : TState.t) (barrier : barrier) :
  Exec.t string (IIS.t * TState.t) :=
  match barrier with
  | Barrier_DMB dmb => (* dmb *)
       match dmb.(DxB_types) with
      | MBReqTypes_All (* dmb sy *) =>
          let vpost :=
            ts.(TState.vrd) ⊔ ts.(TState.vwr)
            ⊔ ts.(TState.vcse) ⊔ ts.(TState.vdsb)
          in
          Exec.ret (IIS.add_nreg vpost iis, TState.update TState.vdmb vpost ts)
      | MBReqTypes_Reads (* dmb ld *) =>
          let vpost := ts.(TState.vrd) ⊔ ts.(TState.vcse) ⊔ ts.(TState.vdsb) in
          Exec.ret (IIS.add_nreg vpost iis, TState.update TState.vdmb vpost ts)
      | MBReqTypes_Writes (* dmb st *) =>
          let vpost := ts.(TState.vwr) ⊔ ts.(TState.vcse) ⊔ ts.(TState.vdsb) in
          Exec.ret (IIS.add_nreg vpost iis, TState.update TState.vdmbst vpost ts)
      end
  | Barrier_DSB dmb => (* dsb *)
      Exec.fail_if (dmb.(DxB_domain) =? MBReqDomain_Nonshareable)
        "Non-shareable barrier are not supported";;
       match dmb.(DxB_types) with
      | MBReqTypes_All (* dsb sy *) =>
          let vpost :=
            ts.(TState.vrd) ⊔ ts.(TState.vwr)
            ⊔ ts.(TState.vdmb) ⊔ ts.(TState.vdmbst)
            ⊔ ts.(TState.vcse) ⊔ ts.(TState.vdsb) ⊔ ts.(TState.vtlbi)
          in
          Exec.ret (IIS.add_nreg vpost iis, TState.update TState.vdsb vpost ts)
      | MBReqTypes_Reads (* dsb ld *) =>
          let vpost := ts.(TState.vrd) ⊔ ts.(TState.vcse) ⊔ ts.(TState.vdsb) in
          Exec.ret (IIS.add_nreg vpost iis, TState.update TState.vdsb vpost ts)
      | MBReqTypes_Writes (* dsb st *) =>
          let vpost := ts.(TState.vwr) ⊔ ts.(TState.vcse) ⊔ ts.(TState.vdsb) in
          Exec.ret (IIS.add_nreg vpost iis, TState.update TState.vdsb vpost ts)
      end
  | Barrier_ISB () => Exec.ret (run_cse iis ts)
  | _ => Exec.Error "Unsupported barrier"
  end.

Definition run_tlbi (tid : nat) (iis : IIS.t) (ts : TState.t) (view : nat)
  (tlbi : TLBI) (mem : Memory.t)
  : Exec.t string (IIS.t * TState.t * Memory.t) :=
  Exec.fail_if (tlbi.(TLBI_shareability) =? Shareability_NSH)
    "Non-shareable TLBIs are not supported";;
  Exec.fail_if (negb (tlbi.(TLBI_rec).(TLBIRecord_regime) =? Regime_EL10))
    "TLBIs in other regimes than EL10 are unsupported";;
  let asid := tlbi.(TLBI_rec).(TLBIRecord_asid) in
  let last := tlbi.(TLBI_rec).(TLBIRecord_level) =? TLBILevel_Last in
  let va := bv_extract 12 36 (tlbi.(TLBI_rec).(TLBIRecord_address)) in
  let vpre := ts.(TState.vcse) ⊔ ts.(TState.vdsb) ⊔ ((*iio*) IIS.nreg iis)
              ⊔ view in
  '(tlbiev : TLBI.t) ←
    match tlbi.(TLBI_rec).(TLBIRecord_op) with
    | TLBIOp_ALL => Exec.ret $ TLBI.All tid
    | TLBIOp_ASID => Exec.ret $ TLBI.Asid tid asid
    | TLBIOp_VAA => Exec.ret $ TLBI.Vaa tid va last
    | TLBIOp_VA => Exec.ret $ TLBI.Va tid asid va last
    | _ => Exec.Error "Unsupported kind of TLBI"
    end;
  let '(time, mem) :=
    match Memory.fulfill tlbiev (TState.prom ts) mem with
    | Some t => (t, mem)
    | None => Memory.promise tlbiev mem
    end in
  Exec.assert (vpre <? time)%nat;;
  let ts :=
    ts |> set TState.prom (delete time)
       |> TState.update TState.vtlbi time
       |> TState.tlbi_cse time
  in
  Exec.ret (IIS.add_nreg time iis, ts, mem).




(** Runs an outcome. *)
Definition run_outcome {A} (tid : nat) (o : outcome A) (iis : IIS.t)
           (ts : TState.t) (init : Memory.initial) (mem : Memory.t)
  : Exec.t string (IIS.t * TState.t * Memory.t * A) :=
  let deps_to_view :=
    fun deps => IIS.from_DepOn deps ts iis in
  match o with
  | RegWrite reg direct deps val =>
      Exec.fail_if (negb direct) "Indirect register write unsupported";;
      let wr_view := deps_to_view deps in
      match Reg.from_arch reg with
      | Some (Reg.App app) =>
          let ts := TState.set_reg app (val, wr_view) ts in
          Exec.ret (iis, ts, mem, ())
      | Some (Reg.Sys sys) => Exec.Error "TODO"
      | None => Exec.Error "Writing to unsupported system register"
      end
  | RegRead reg direct => Exec.Error "TODO"
  | MemRead 8 rr =>
      '(ts, iis, val) ← run_mem_read rr iis ts init mem;
      Exec.ret (iis, ts, mem, inl (val, None))
  | MemRead 4 rr => (* ifetch *)
      opcode ← run_mem_read4 rr iis ts init mem;
      Exec.ret (iis, ts, mem, inl (opcode, None))
  | MemRead _ _ => Exec.Error "Memory read of size other than 8 or 4"
  | MemWrite 8 wr =>
      addr ← Exec.error_none "PA not supported" $ Loc.from_pa wr.(WriteReq.pa);
      let vaddr := deps_to_view wr.(WriteReq.addr_deps) in
      let data := wr.(WriteReq.value) in
      let vdata := deps_to_view wr.(WriteReq.data_deps) in
      let viio := IIS.nreg iis in
      match wr.(WriteReq.access_kind) with
      | AK_explicit eak =>
          '(ts, mem) ← write_mem_xcl tid addr vaddr vdata viio eak ts mem data;
          Exec.ret (iis, ts, mem, inl None)
      | AK_ifetch () => Exec.Error "Write of type ifetch ???"
      | AK_ttw () => Exec.Error "Write of type TTW ???"
      | _ => Exec.Error "Unsupported non-explicit write"
      end
  | MemWrite _ _ => Exec.Error "Memory write of size other than 8"
  | BranchAnnounce _ deps =>
      let ts := TState.update TState.vspec (deps_to_view deps) ts in
      Exec.ret (iis, ts, mem, ())
  | Barrier barrier =>
      '(iis, ts) ← run_barrier iis ts barrier;
      Exec.ret (iis, ts, mem, ())
  | TlbOp deps tlbi =>
      '(iis, ts, mem) ← run_tlbi tid iis ts (deps_to_view deps) tlbi mem;
      Exec.ret (iis, ts, mem, ())
  | ReturnException _ =>
      let '(iis, ts) := run_cse iis ts in
      Exec.ret (iis, ts, mem, ())
  | GenericFail s => Exec.Error ("Instruction failure: " ++ s)%string
  | Choose n =>
      v ← Exec.choose (bv n);
      Exec.ret(iis, ts, mem, v)
  | Discard => Exec.discard
  | _ => Exec.Error "Unsupported outcome"
  end.


(** Runs an instruction monad object run_outcome as the effect handler *)
Fixpoint run_iMon {A : Type} (i : iMon A) (iis : IIS.t) (tid : nat)
         (ts : TState.t) (init : Memory.initial) (mem : Memory.t)
  : Exec.t string (TState.t * Memory.t * A) :=
  match i with
  | Ret a => Exec.ret (ts, mem, a)
  | Next o next =>
      '(iis, ts, mem, res) ← run_outcome tid o iis ts init mem;
      run_iMon (next res) iis tid ts init mem
  end.

(*** Implement GenPromising ***)

Section PromStruct.
  Context (isem : iSem).

  Definition tState' : Type := TState.t * isem.(isa_state).

  Definition tState_init' (tid : nat) (mem : memoryMap) (regs : registerMap)
      : tState':=
    (TState.init mem regs, isem.(init_state) tid).

  Definition tState_nopromises' (tstate : tState') :=
    tstate.1.(TState.prom) |> is_emptyb.

  Local Notation pThread := (PThread.t tState' Ev.t).

(** Run an iSem on a pThread  *)
  Definition run_pthread (pthread : pThread) : Exec.t string pThread :=
    let imon := isem.(semantic) pthread.(PThread.tstate).2 in
    let initmem := pthread.(PThread.initmem) |> Memory.initial_from_memMap in
    '(ts, mem, isa_st) ←@{Exec.t string}
      run_iMon
        imon
        IIS.init
        pthread.(PThread.tid)
        pthread.(PThread.tstate).1
        initmem
        pthread.(PThread.events);
    pthread |> setv PThread.tstate (ts, isa_st)
            |> setv PThread.events mem
            |> Exec.ret.


  (* A thread is allowed to promise any promises with the correct tid.
    This a non-certified promising model *)
  Definition allowed_promises_nocert (pthread : pThread) :=
    fun ev => Ev.tid ev = pthread.(PThread.tid).
  Arguments allowed_promises_nocert _ _ /.

  Definition emit_promise' (pthread : pThread) (ev : Ev.t) : tState' :=
    let vev := length pthread.(PThread.events) in
    pthread.(PThread.tstate) |> set fst (TState.promise vev).

  Definition memory_snapshot' (memMap : memoryMap) (mem : Memory.t) : memoryMap :=
    Memory.to_memMap (Memory.initial_from_memMap memMap) mem.

  Definition UMPromising_nocert' : PromisingModel isem :=
    {|tState := tState';
      tState_init := tState_init';
      tState_regs := TState.reg_map ∘ fst;
      tState_isa_state := fun x => x.2;
      tState_nopromises := tState_nopromises';
      mEvent := Ev.t;
      run_instr := run_pthread;
      allowed_promises := allowed_promises_nocert;
      emit_promise := emit_promise';
      memory_snapshot := memory_snapshot';
    |}.

  Definition UMPromising_nocert := Promising_to_Modelnc UMPromising_nocert'.

End PromStruct.
Arguments allowed_promises_nocert _ _ _ /.
