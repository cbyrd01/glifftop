//! Checks the client's frame acks: exactly one per video frame, in the order sent.

use std::collections::VecDeque;

#[derive(Default)]
pub struct AckTracker {
    /// Frames sent and not yet acked, oldest first.
    pending: VecDeque<u64>,
    /// The last frame id sent (0 before any; ids start at 1 and only grow): an ack at or
    /// below it that isn't pending is a duplicate.
    last_sent: u64,
}

impl AckTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn sent(&mut self, frame_id: u64) {
        self.pending.push_back(frame_id);
        self.last_sent = frame_id;
    }

    pub fn acked(&mut self, frame_id: u64) -> Result<(), String> {
        match self.pending.front() {
            Some(&next) if next == frame_id => {
                self.pending.pop_front();
                Ok(())
            }
            _ if self.pending.contains(&frame_id) => Err(format!(
                "frame {frame_id} acked before frame {}",
                self.pending.front().expect("contains implies non-empty")
            )),
            _ if frame_id != 0 && frame_id <= self.last_sent => {
                Err(format!("frame {frame_id} acked twice"))
            }
            _ => Err(format!("frame {frame_id} acked but never sent")),
        }
    }

    /// Frames sent and not acked yet.
    pub fn outstanding(&self) -> usize {
        self.pending.len()
    }

    /// Every frame sent has been acked.
    pub fn finish(&self) -> Result<(), String> {
        match self.pending.front() {
            None => Ok(()),
            Some(id) => Err(format!("frame {id} was never acked ({} missing)", self.pending.len())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sent(ids: &[u64]) -> AckTracker {
        let mut tracker = AckTracker::new();
        for &id in ids {
            tracker.sent(id);
        }
        tracker
    }

    #[test]
    fn in_order_acks_pass() {
        let mut tracker = sent(&[1, 2, 3]);
        assert_eq!(tracker.outstanding(), 3);
        for id in 1..=3 {
            tracker.acked(id).unwrap();
        }
        assert_eq!(tracker.outstanding(), 0);
        tracker.finish().unwrap();
    }

    #[test]
    fn duplicate_ack_fails() {
        let mut tracker = sent(&[1, 2]);
        tracker.acked(1).unwrap();
        let error = tracker.acked(1).unwrap_err();
        assert!(error.contains("frame 1") && error.contains("twice"), "{error}");
    }

    #[test]
    fn unknown_ack_fails() {
        let mut tracker = sent(&[1]);
        let error = tracker.acked(7).unwrap_err();
        assert!(error.contains("frame 7") && error.contains("never sent"), "{error}");
    }

    #[test]
    fn out_of_order_ack_fails() {
        let mut tracker = sent(&[1, 2]);
        let error = tracker.acked(2).unwrap_err();
        assert!(error.contains("frame 2") && error.contains("before frame 1"), "{error}");
    }

    #[test]
    fn ack_for_frame_zero_was_never_sent() {
        let mut tracker = sent(&[1]);
        tracker.acked(1).unwrap();
        let error = tracker.acked(0).unwrap_err();
        assert!(error.contains("frame 0") && error.contains("never sent"), "{error}");
    }

    #[test]
    fn missing_ack_fails_at_finish() {
        let mut tracker = sent(&[1, 2]);
        tracker.acked(1).unwrap();
        let error = tracker.finish().unwrap_err();
        assert!(error.contains("frame 2"), "{error}");
    }
}
