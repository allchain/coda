## Terminology

history root: the oldest node in root history

## Summary

The origin transition catchup design has performance issues. In
current implementation, we would always downloading a list of transitions
from the requested hash to peer's history root.
The minimum number of transitions that transition catchup would request is
k + 1 under current implementation. This is not very efficient in a realistic
setting where k is ~3000. The new design features
1) avoids requesting unnecessary transitions;
2) instead of having a monolithic request to download everything; try to
   download small pieces from different peers at the same time.

## Motivation

The new design would improve the efficiency of doing ledger catchup.

## Detailed design

Split ledger catchup into 2 phases:

1) Instead of
   * requesting a path/list of transitions from peer's history root to the requested hash,
   * requesting a merkle path/list from peer's history root to the requested hash together with their root history transition.
   
   * The merkle path/list contains a list of *state_body_hash*es. Upon received
the merkle_path/list, we could verify that the merkle path by first trying
to find the history root in our frontier or root_history and then call
*Merkle_list.verify* on that merkle path. This would guarantee that the
peer didn't send us a list of garbage and it also guarantees that the
order is correct. And we could then reconstruct a list of *state_hash*es
from the list of *state_body_hash*es. Using this list of *state_hash*es we
can find the missing transitions by repeated searching *state_hash*es until
we find one (the one we find is the closest ancestor in our transition
frontier).
   
2) Depending on the size of the list of the missing transitions, spawn one or
more parallel requests to get the missing transitions from peers. We could
verify the list of transitions that send by peer against the list of
state_hashes.

For trust system, I would describe different actions for the 2 phases described
above:
1) * If a peer isn't able to handle the request, we shouldn't decrease their
     trust score.
   * If the peer send us the a merkle path that doesn't pass verification we
     should flag the peer as **Violated_protocol**.
   
2) * If a peer isn't able to handle the request, we shouldn't decrease their
     trust score.
   * If a peer returns a list of transitions whose state_hashes are different
     from what we have, we should flag the peer as **Violate_protocol**.
   * If transitions returned by the peer don't pass verification or their
     proofs are invalid, we should decrease the peer's trust score accordingly.

## Drawbacks

The new design has the overhead of first downloading a merkle path. But this
overhead is negligible comparing to the overhead of downloading unnecessary
transitions.

## Unsolved questions

It's not very clear to me what's a reasonable size of the list of transition
that we should download in 1 request.

## Rationale and alternatives

We currently have an almost stable testnet which is quite small. We are
moving toward the direction of solving the known performance issues that would
hinder us from scaling up to a more realistic setting.

## Prior art

The current implementation is summaried in the `Summary` part.