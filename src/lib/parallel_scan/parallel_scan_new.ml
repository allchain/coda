open Core

module Sequence_number = struct
  type t = int [@@deriving sexp]
end

(*Each node on the tree is viewed as a job that needs to be completed. When a job is completed, it creates a new "Todo" job and marks the old job as "Done"*)
module Job_status = struct
  type t = Todo | Done [@@deriving sexp]
end

(*number of jobs that can be added to this tree. This number corresponding to a specific level of the tree. New jobs received is distributed across the tree based on this number. *)
type weight = int [@@deriving sexp]

(*Base Job: Proving new transactions*)
module Base = struct
  type 'd base =
    | Empty
    | Full of {job: 'd; seq_no: Sequence_number.t; status: Job_status.t}
  [@@deriving sexp]

  type 'd t = weight * 'd base [@@deriving sexp]
end

(* Merge Job: Merging two proofs*)
module Merge = struct
  type 'a merge =
    | Empty
    | Part of 'a (*Only the left component of the job is available yet since we always complete the jobs from left to right*)
    | Full of
        { left: 'a
        ; right: 'a
        ; seq_no: Sequence_number.t (*Update no, for debugging*)
        ; status: Job_status.t }
  [@@deriving sexp]

  type 'a t = (weight * weight) * 'a merge [@@deriving sexp]
end

(*All the jobs on a tree that can be done. Base.Full and Merge.Bcomp*)
module Available_job = struct
  type ('a, 'd) t = Base of 'd | Merge of 'a * 'a [@@deriving sexp]
end

(*New jobs to be added (including new transactions or new merge jobs)*)
module New_job = struct
  type ('a, 'd) t = Base of 'd | Merge of 'a [@@deriving sexp]
end

module Tree = struct
  type ('a, 'd) t =
    | Leaf of 'd
    | Node of {depth: int; value: 'a; sub_tree: ('a * 'a, 'd * 'd) t}
  [@@deriving sexp]

  (*Eg: Tree depth = 3

    Node M
    |
    Node (M,M)
    |
    Node ((M,M),(M,M))
    |
    Leaf (((B,B),(B,B)),((B,B),(B,B))) 
   *)

  (*mapi where i is the level of the tree*)
  let rec map_depth : type a b c d.
      fa:(int -> a -> b) -> fd:(d -> c) -> (a, d) t -> (b, c) t =
   fun ~fa ~fd tree ->
    match tree with
    | Leaf d ->
        Leaf (fd d)
    | Node {depth; value; sub_tree} ->
        Node
          { depth
          ; value= fa depth value
          ; sub_tree=
              map_depth
                ~fa:(fun i (x, y) -> (fa i x, fa i y))
                ~fd:(fun (x, y) -> (fd x, fd y))
                sub_tree }

  let map : type a b c d. fa:(a -> b) -> fd:(d -> c) -> (a, d) t -> (b, c) t =
   fun ~fa ~fd tree -> map_depth tree ~fd ~fa:(fun _ -> fa)

  (* foldi where i is the cur_level*)
  let rec fold_depth : type a c d.
         fa:(int -> a -> c)
      -> fd:(d -> c)
      -> f:(c -> c -> c)
      -> init:c
      -> (a, d) t
      -> c =
   fun ~fa ~fd ~f ~init:acc t ->
    match t with
    | Leaf d ->
        f acc (fd d)
    | Node {depth; value; sub_tree} ->
        let acc' =
          fold_depth ~f
            ~fa:(fun i (x, y) -> f (fa i x) (fa i y))
            ~fd:(fun (x, y) -> f (fd x) (fd y))
            ~init:acc sub_tree
        in
        f acc' (fa depth value)

  let fold : type a c d.
      fa:(a -> c) -> fd:(d -> c) -> f:(c -> c -> c) -> init:c -> (a, d) t -> c
      =
   fun ~fa ~fd ~f ~init t -> fold_depth t ~init ~fa:(fun _ -> fa) ~fd ~f

  (*List of jobs that map to a specific level on the tree**)
  module Job_list = struct
    module T = struct
      type 'a t = Single of 'a | Double of ('a * 'a) t [@@deriving sexp]
    end

    type ('a, 'b) tree = ('a, 'b) t

    include T

    let rec split : type a. a t -> (a -> a * a) -> (a * a) t =
     fun lst f ->
      match lst with
      | Single a ->
          Single (f a)
      | Double t ->
          let sub = split t (fun (x, y) -> (f x, f y)) in
          Double sub

    let rec of_tree : type a b c d.
           c t
        -> (a, d) tree
        -> weight_a:(a -> b * b)
        -> weight_d:(d -> b * b)
        -> f_split:(b * b -> c -> c * c)
        -> on_level:int
        -> c t =
     fun job_list tree ~weight_a ~weight_d ~f_split ~on_level ->
      match tree with
      | Node {depth; value; sub_tree} ->
          if depth = on_level then job_list
          else
            let l, r = weight_a value in
            let new_job_list = split job_list (f_split (l, r)) in
            Double
              (of_tree new_job_list sub_tree
                 ~weight_a:(fun (a, b) -> (weight_a a, weight_a b))
                 ~weight_d:(fun (a, b) -> (weight_d a, weight_d b))
                 ~f_split:(fun ((x1, y1), (x2, y2)) (a, b) ->
                   (f_split (x1, y1) a, f_split (x2, y2) b) )
                 ~on_level)
      | Leaf b ->
          Double (split job_list (f_split (weight_d b)))

    let of_list_and_tree lst tree on_level =
      of_tree (Single lst) tree ~weight_a:fst
        ~weight_d:(fun d -> (fst d, 0))
        ~f_split:(fun (l, r) a -> (List.take a l, List.take (List.drop a l) r))
        ~on_level

    (*Just the nested jobs*)
    let to_jobs : type a. a t -> a =
     fun t ->
      let rec go : type a. a t -> a * a =
       fun job_list ->
        match job_list with Single a -> (a, a) | Double js -> fst (go js)
      in
      fst @@ go t
  end

  (*
    a -> 'a Merge.t
    b -> New_job.t Job_list.t
    c -> weight
    d -> 'd Base.t
    e -> 'a (final proof)
    fa, fb are to update the nodes with new jobs and mark old jobs to "Done"*)
  let rec update' : type a b c d e.
         fa:(b -> int -> a -> a * e option)
      -> fd:((*int here is the current level*)
             b -> d -> d)
      -> weight_a:(a -> c * c)
      -> jobs:b Job_list.t
      -> jobs_split:(c * c -> b -> b * b)
      -> (a, d) t
      -> (a, d) t * e option =
   fun ~fa ~fd ~weight_a ~jobs ~jobs_split t ->
    match t with
    | Leaf d ->
        (Leaf (fd (Job_list.to_jobs jobs) d), None)
    | Node {depth; value; sub_tree} ->
        let weight_left_subtree, weight_right_subtree = weight_a value in
        (*update the jobs at the current level*)
        let value', scan_result = fa (Job_list.to_jobs jobs) depth value in
        (*split the jobs for the next level*)
        let new_jobs_list =
          Job_list.split jobs
            (jobs_split (weight_left_subtree, weight_right_subtree))
        in
        (*get the updated subtree*)
        let sub, _ =
          update'
            ~fa:(fun (b, b') i (x, y) ->
              let left = fa b i x in
              let right = fa b' i y in
              ((fst left, fst right), Option.both (snd left) (snd right)) )
            ~fd:(fun (b, b') (x, x') -> (fd b x, fd b' x'))
            ~weight_a:(fun (a, b) -> (weight_a a, weight_a b))
            ~jobs_split:(fun (x, y) (a, b) -> (jobs_split x a, jobs_split y b))
            ~jobs:new_jobs_list sub_tree
        in
        (Node {depth; value= value'; sub_tree= sub}, scan_result)

  let update :
         ('b, 'c) New_job.t list
      -> update_level:int
      -> sequence_no:int
      -> ('a, 'd) t
      -> ('a, 'd) t * 'b option =
   fun completed_jobs ~update_level ~sequence_no:seq_no tree ->
    let add_merges (jobs : ('b, 'c) New_job.t list) cur_level (weight, m) =
      let reset_weight a =
        match a with
        | 0, 0 ->
            (*add new weights for all the levels above the cur_level since  those are the next jobs we would be expecting*)
            let c = Int.pow 2 update_level / Int.pow 2 (2 + cur_level) in
            if update_level - 1 = 0 then (1, 0) else (c, c)
        | _ ->
            a
      in
      let left, right = weight in
      if cur_level = update_level - 1 then
        (*Create new jobs from the completed ones*)
        let new_weight, m' =
          match (jobs, m) with
          | [], e ->
              (weight, e)
          | [New_job.Merge a; Merge b], Merge.Empty ->
              ( (left - 1, right - 1)
              , Merge.Full {left= a; right= b; seq_no; status= Job_status.Todo}
              )
          | [Merge a], Empty ->
              ((left - 1, right), Part a)
          | [Merge b], Part a ->
              ( (left, right - 1)
              , Full {left= a; right= b; seq_no; status= Job_status.Todo} )
          | [Base _], Empty | [Base _], Part _ | [Base _; Base _], Empty ->
              ((left, right), m)
          | _ ->
              failwith "Invalid merge job (level-1)"
        in
        ((reset_weight new_weight, m'), None)
      else if cur_level = update_level then
        (*Mark as Done*)
        match (jobs, m) with
        | [Merge a], Full ({status= Job_status.Todo; _} as x) ->
            let new_job = Merge.Full {x with status= Job_status.Done} in
            let scan_result, weight' =
              if cur_level = 0 then (Some a, (0, 0)) else (None, weight)
            in
            ((weight', new_job), scan_result)
        | [], m ->
            ((weight, m), None)
        | _ ->
            failwith "Invalid merge job"
      else if cur_level < update_level - 1 then
        match jobs with
        | [] | Base _ :: _ ->
            ((weight, m), None)
        | _ ->
            let jobs_left = List.length (List.take jobs left) in
            let jobs_right =
              List.length (List.take (List.drop jobs left) right)
            in
            let new_weight =
              (max 0 (left - jobs_left), max 0 (right - jobs_right))
            in
            ((reset_weight new_weight, m), None)
      else ((weight, m), None)
    in
    let add_bases jobs (weight, d) =
      match (jobs, d) with
      | [], e ->
          (weight, e)
      | [New_job.Base d], Base.Empty ->
          (weight - 1, Base.Full {job= d; seq_no; status= Job_status.Todo})
      | [New_job.Merge _], Base.Full b ->
          (weight, Base.Full {b with status= Job_status.Done})
      | _ ->
          failwith "Invalid base job"
    in
    let jobs = Job_list.Single completed_jobs in
    update' ~fa:add_merges ~fd:add_bases tree ~weight_a:fst ~jobs
      ~jobs_split:(fun (l, r) a -> (List.take a l, List.take (List.drop a l) r))

  let jobs_on_level :
      depth:int -> level:int -> ('a, 'd) t -> ('b, 'c) Available_job.t list =
   fun ~depth ~level tree ->
    if level = depth then
      fold ~init:[] ~f:List.append
        ~fa:(fun _ -> [])
        ~fd:(fun d ->
          match d with
          | _weight, Base.Full {job; status= Todo; _} ->
              [Available_job.Base job]
          | _ ->
              [] )
        tree
    else
      fold_depth ~init:[] ~f:List.append
        ~fa:(fun i a ->
          if i = level then
            match a with
            | _weight, Merge.Full {left; right; status= Todo; _} ->
                [Available_job.Merge (left, right)]
            | _ ->
                []
          else [] )
        ~fd:(fun _ -> [])
        tree

  let to_data : ('a, 'd) t -> int -> ('b, 'c) Available_job.t list =
   fun tree max_base_jobs ->
    let depth = Int.ceil_log2 max_base_jobs + 1 in
    jobs_on_level ~level:depth ~depth tree

  let rec view_tree : type a d.
      (a, d) t -> show_a:(a -> string) -> show_d:(d -> string) -> string =
   fun tree ~show_a ~show_d ->
    match tree with
    | Leaf d ->
        sprintf !"Leaf %s\n" (show_d d)
    | Node {value; sub_tree; _} ->
        let curr = sprintf !"Node %s\n" (show_a value) in
        let subtree =
          view_tree sub_tree
            ~show_a:(fun (x, y) -> sprintf !"%s  %s" (show_a x) (show_a y))
            ~show_d:(fun (x, y) -> sprintf !"%s  %s" (show_d x) (show_d y))
        in
        curr ^ subtree
end

(*This struture works well because we always complete all the nodes on a specific level before proceeding to the next level*)

type ('a, 'd) t =
  { trees: ('a Merge.t, 'd Base.t) Tree.t list (*use non empty list*)
  ; acc: (int * ('a * 'd list)) option
        (*last emitted proof and the corresponding transactions*)
  ; next_base_pos: int
        (*All new base jobs will start from the first tree in the list*)
  ; recent_tree_data: 'd list
  ; other_trees_data: 'd list list
        (*Keeping track of all the transactions corresponding to a proof returned*)
  ; curr_job_seq_no: int (*Sequence number for the jobs added every block*)
  ; max_base_jobs: int (*transaction_capacity_log_2*)
  ; delay: int }
[@@deriving sexp]

let create_tree_for_level ~level ~depth ~merge ~base =
  let rec go : type a d. int -> (int -> a) -> d -> (a, d) Tree.t =
   fun d fmerge base ->
    if d >= depth then Leaf base
    else
      let sub_tree = go (d + 1) (fun i -> (fmerge i, fmerge i)) (base, base) in
      Node {depth= d; value= fmerge d; sub_tree}
  in
  let base_weight = if level = -1 then 0 else 1 in
  go 0
    (fun d ->
      let weight =
        if level = -1 then (0, 0)
        else
          let x = Int.pow 2 level / Int.pow 2 (d + 1) in
          (x, x)
      in
      (weight, merge) )
    (base_weight, base)

let create_tree ~depth =
  create_tree_for_level ~level:depth ~depth ~merge:Merge.Empty ~base:Base.Empty

let max_trees t = ((Int.ceil_log2 t.max_base_jobs + 1) * (t.delay + 1)) + 1

let create : max_base_jobs:int -> delay:int -> ('a, 'd) t =
 fun ~max_base_jobs ~delay ->
  let depth = Int.ceil_log2 max_base_jobs in
  let first_tree = create_tree ~depth in
  { trees= [first_tree]
  ; acc= None
  ; next_base_pos= 0
  ; recent_tree_data= []
  ; other_trees_data= []
  ; curr_job_seq_no= 0
  ; max_base_jobs
  ; delay }

let work_to_do :
    ('a, 'd) Tree.t list -> max_base_jobs:int -> ('b, 'c) Available_job.t list
    =
 fun trees ~max_base_jobs ->
  let depth = Int.ceil_log2 max_base_jobs in
  List.concat_mapi trees ~f:(fun i tree ->
      Tree.jobs_on_level ~depth ~level:(depth - i) tree )

let all_work : type a d. (a, d) t -> (a, d) Available_job.t list =
 fun t ->
  let depth = Int.ceil_log2 t.max_base_jobs in
  let rec go trees work_list delay =
    if List.length trees = depth + 1 then
      let work = work_to_do trees ~max_base_jobs:t.max_base_jobs |> List.rev in
      work @ work_list
    else
      let work_trees =
        List.take
          (List.filteri trees ~f:(fun i _ -> i % delay = delay - 1))
          (depth + 1)
      in
      let work =
        work_to_do work_trees ~max_base_jobs:t.max_base_jobs |> List.rev
      in
      let remaining_trees =
        List.filteri trees ~f:(fun i _ -> i % delay <> delay - 1)
      in
      go remaining_trees (work @ work_list) (max 2 (delay - 1))
  in
  let work_list = go (List.tl_exn t.trees) [] (t.delay + 1) in
  let current_leaves = Tree.to_data (List.hd_exn t.trees) t.max_base_jobs in
  List.rev_append work_list current_leaves

let work_for_current_tree : type a d. (a, d) t -> (a, d) Available_job.t list =
 fun t ->
  let delay = t.delay + 1 in
  let depth = Int.ceil_log2 t.max_base_jobs in
  let work_trees =
    List.take
      (List.filteri (List.tl_exn t.trees) ~f:(fun i _ -> i % delay = delay - 1))
      (depth + 1)
  in
  work_to_do work_trees ~max_base_jobs:t.max_base_jobs

let update : type a d.
    data:d list -> completed_jobs:a list -> (a, d) t -> (a, d) t * a option =
 fun ~data ~completed_jobs t ->
  assert (List.length data <= t.max_base_jobs) ;
  assert (List.length completed_jobs <= (2 * t.max_base_jobs) - 1) ;
  let delay = t.delay + 1 in
  let depth = Int.ceil_log2 t.max_base_jobs in
  let new_base_jobs = List.map data ~f:(fun j -> New_job.Base j) in
  let new_merge_jobs = List.map completed_jobs ~f:(fun j -> New_job.Merge j) in
  let required_job_count = function
    | Tree.Node {value= job_count, _; _} ->
        fst job_count + snd job_count
    | Leaf b ->
        fst b
  in
  let next_seq = t.curr_job_seq_no + 1 in
  Core.printf !"adding new merges. Tree count: %d\n%!" (List.length t.trees) ;
  (*Add the completed jobs*)
  let updated_trees_merge, result_opt, _remaining_merge_jobs =
    List.foldi (List.tl_exn t.trees) ~init:([], None, new_merge_jobs)
      ~f:(fun i (trees, scan_result, jobs) tree ->
        if i % delay = delay - 1 then
          (*All the trees with delay number of trees between them*)
          let tree', scan_result' =
            Tree.update
              (List.take jobs (required_job_count tree))
              ~update_level:(depth - (i / delay))
              ~sequence_no:next_seq tree
          in
          ( tree' :: trees
          , scan_result'
          , List.drop jobs (required_job_count tree) )
        else (tree :: trees, scan_result, jobs) )
  in
  let updated_trees_merge = List.rev updated_trees_merge in
  Core.printf
    !"update tree count before %d\n"
    (List.length updated_trees_merge) ;
  (*If the root merge job is done which is always from the last tree, delete that tree*)
  let updated_trees_merge =
    if Option.is_some result_opt then
      fst
        (List.split_n updated_trees_merge (List.length updated_trees_merge - 1))
    else updated_trees_merge
  in
  Core.printf
    !"result %b\nupdate tree count after %d\n"
    (Option.is_some result_opt)
    (List.length updated_trees_merge) ;
  Core.printf !"adding new bases \n%!" ;
  (*Add new base jobs. This always on the first tree*)
  let updated_trees_base =
    let latest_tree = List.hd_exn t.trees in
    let available_space = required_job_count latest_tree in
    let jobs_for_cur_tree, jobs_for_new_tree =
      List.split_n new_base_jobs available_space
    in
    let cur_tree_updated, _ =
      Tree.update jobs_for_cur_tree ~update_level:depth ~sequence_no:next_seq
        latest_tree
    in
    let more_space_on_cur_tree =
      available_space > List.length jobs_for_cur_tree
    in
    match (List.is_empty jobs_for_new_tree, more_space_on_cur_tree) with
    | _, true ->
        [cur_tree_updated]
    | true, _ ->
        (*Simple create an empty tree for the next update*)
        [create_tree ~depth; cur_tree_updated]
    | false, _ ->
        (*Add the remaining jobs on to a new tree*)
        let new_tree, _ =
          Tree.update jobs_for_cur_tree ~update_level:depth
            ~sequence_no:next_seq (create_tree ~depth)
        in
        [new_tree; cur_tree_updated]
  in
  let trees = updated_trees_base @ updated_trees_merge in
  let t = ({t with trees; curr_job_seq_no= next_seq}, result_opt) in
  assert (List.length trees <= max_trees (fst t)) ;
  t

let view_int_trees (tree : (int Merge.t, int Base.t) Tree.t) =
  let show_status = function Job_status.Done -> "D" | Todo -> "T" in
  let show_a a =
    match snd a with
    | Merge.Full {seq_no; status; left; right} ->
        sprintf "(F %d %d %s)" (left + right) seq_no (show_status status)
    | Part _ ->
        "P"
    | Empty ->
        "E"
  in
  let show_d d =
    match snd d with
    | Base.Empty ->
        "E"
    | Base.Full {seq_no; status; job} ->
        sprintf "(Ba %d %d %s)" job seq_no (show_status status)
  in
  Tree.view_tree tree ~show_a ~show_d

let%test_unit "test tree" =
  let t : (int, int) t = create ~max_base_jobs:8 ~delay:1 in
  (*Core.printf !"init tree %{sexp: (int, int) t}\n %!" t ;*)
  Core.printf !"trees\n%s\n%!"
    (String.concat (List.map t.trees ~f:view_int_trees)) ;
  let _t' =
    List.foldi ~init:t (List.init 20 ~f:Fn.id) ~f:(fun i t' _ ->
        Core.printf !"Tree count %d\n" (List.length t'.trees) ;
        let data = List.init 8 ~f:(fun j -> i + j) in
        let work = work_for_current_tree t' in
        let new_merges =
          List.map work ~f:(fun job ->
              match job with Base i -> i | Merge (i, j) -> i + j )
        in
        let t', result_opt = update ~data ~completed_jobs:new_merges t' in
        let expected_result = List.sum (module Int) data ~f:Fn.id in
        Core.printf !"tree %{sexp: (int, int) t}\n %!" t' ;
        Core.printf
          !"Result %{sexp: int option} expected %d\ntrees\n%s\n%!"
          result_opt expected_result
          (String.concat ~sep:"\n" (List.map t'.trees ~f:view_int_trees)) ;
        (*assert (
          Option.value ~default:expected_result result_opt = expected_result ) ;*)
        t' )
  in
  ()

let%test_unit "job list" =
  let _t : (int, int) t = create ~max_base_jobs:8 ~delay:1 in
  let _merge_empty : int Merge.merge = Merge.Empty in
  let base_empty : int Base.base = Base.Empty in
  let tree : (int Merge.t, int Base.t) Tree.t =
    Tree.Node
      { depth= 0
      ; value= ((4, 4), Merge.Empty)
      ; sub_tree=
          Node
            { depth= 1
            ; value= (((2, 2), Empty), ((2, 2), Empty))
            ; sub_tree=
                Node
                  { depth= 2
                  ; value=
                      ( (((1, 1), Empty), ((1, 1), Empty))
                      , (((1, 1), Empty), ((1, 1), Empty)) )
                  ; sub_tree=
                      Leaf
                        ( ( ((0, base_empty), (0, base_empty))
                          , ((1, base_empty), (1, base_empty)) )
                        , ( ((1, base_empty), (1, base_empty))
                          , ((1, base_empty), (1, base_empty)) ) ) } } }
  in
  let job_list =
    Tree.Job_list.of_list_and_tree [1; 2; 3; 4; 5; 6; 7; 8] tree 2
  in
  Core.printf !"job list: %{sexp: int list Tree.Job_list.t}\n%!" job_list ;
  ()