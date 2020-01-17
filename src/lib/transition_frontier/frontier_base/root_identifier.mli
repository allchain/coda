open Coda_base

[%%versioned:
module Stable : sig
  module V1 : sig
    type t = {state_hash: State_hash.t; frontier_hash: Frontier_hash.t}
  end
end]

type t = Stable.Latest.t [@@deriving yojson]
