"""Phase 0 prototype for NAME_TOKENIZED v2.

Validates the multi-substream + DUP-pool + PREFIX-MATCH design on real
corpora before committing to the C kernel implementation.

Per feedback_phase_0_spec_proof: this is a pure-Python end-to-end
validation. If chr22 savings < 3 MB at the chosen wire constants
(N=8, B=4096), the design is revised before any C/Java/ObjC code.
"""
