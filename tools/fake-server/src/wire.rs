//! Gliff framing over blocking std::io: an 8-byte little-endian header (body length, payload
//! length), the CBOR body, then the payload bytes. Same layout and limits as upstream
//! gliff-transport, without its async runtime.

use gliff_proto::frame::{HEADER_LEN, MAX_FRAME_BODY, MAX_FRAME_PAYLOAD, MAX_PAYLOAD};
use std::io::{self, Read, Write};

/// A message's CBOR body, as upstream's derive encodes it.
pub fn body<T: minicbor::Encode<()>>(message: &T) -> Vec<u8> {
    minicbor::to_vec(message).expect("encoding to a Vec cannot fail")
}

/// One frame as read: the message body and everything after it.
#[derive(Debug, PartialEq)]
pub struct Frame {
    pub body: Vec<u8>,
    pub payload: Vec<u8>,
}

/// Writes one frame: header, body, then the payloads back to back. Flushes, so the client
/// sees each frame as soon as it is written.
pub fn write_frame(out: &mut impl Write, body: &[u8], payloads: &[&[u8]]) -> io::Result<()> {
    // Upstream `write_msg_with_payloads`: the body, then each payload, then the total.
    if body.len() > MAX_FRAME_BODY {
        return Err(refused(&format!("body of {} bytes is over the limit", body.len())));
    }
    if let Some(p) = payloads.iter().find(|p| p.len() > MAX_PAYLOAD as usize) {
        return Err(refused(&format!("payload of {} bytes is over the limit", p.len())));
    }
    let payload_len: usize = payloads.iter().map(|p| p.len()).sum();
    if payload_len > MAX_FRAME_PAYLOAD as usize {
        return Err(refused(&format!("payloads of {payload_len} bytes are over the limit")));
    }
    out.write_all(&(body.len() as u32).to_le_bytes())?;
    out.write_all(&(payload_len as u32).to_le_bytes())?;
    out.write_all(body)?;
    for payload in payloads {
        out.write_all(payload)?;
    }
    out.flush()
}

/// Reads one frame. `Ok(None)` at a clean end of stream (no bytes of a next frame); an end
/// partway through a frame is `UnexpectedEof`.
pub fn read_frame(input: &mut impl Read) -> io::Result<Option<Frame>> {
    let mut header = [0u8; HEADER_LEN];
    let mut filled = 0;
    while filled < HEADER_LEN {
        match input.read(&mut header[filled..]) {
            Ok(0) if filled == 0 => return Ok(None),
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => filled += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    let body_len = u32::from_le_bytes([header[0], header[1], header[2], header[3]]);
    let payload_len = u32::from_le_bytes([header[4], header[5], header[6], header[7]]);
    if body_len as usize > MAX_FRAME_BODY {
        return Err(invalid(&format!("body of {body_len} bytes is over the limit")));
    }
    if payload_len > MAX_FRAME_PAYLOAD {
        return Err(invalid(&format!("payload of {payload_len} bytes is over the limit")));
    }
    let mut body = vec![0; body_len as usize];
    input.read_exact(&mut body)?;
    let mut payload = vec![0; payload_len as usize];
    input.read_exact(&mut payload)?;
    Ok(Some(Frame { body, payload }))
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_owned())
}

fn refused(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn round_trips_body_and_payloads() {
        let mut bytes = Vec::new();
        write_frame(&mut bytes, &[1, 2, 3], &[&[9, 9], &[8]]).unwrap();
        assert_eq!(bytes[..HEADER_LEN], [3, 0, 0, 0, 3, 0, 0, 0]);
        let mut input = Cursor::new(bytes);
        let frame = read_frame(&mut input).unwrap().unwrap();
        assert_eq!(frame, Frame { body: vec![1, 2, 3], payload: vec![9, 9, 8] });
        assert_eq!(read_frame(&mut input).unwrap(), None);
    }

    #[test]
    fn clean_end_is_none() {
        assert_eq!(read_frame(&mut Cursor::new(Vec::new())).unwrap(), None);
    }

    #[test]
    fn end_mid_frame_is_an_error() {
        let mut bytes = Vec::new();
        write_frame(&mut bytes, &[1, 2, 3], &[&[9, 9]]).unwrap();
        bytes.truncate(10);
        let error = read_frame(&mut Cursor::new(bytes)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof);
    }

    /// Upstream `write_msg_with_payloads`: body, then each payload, then the total.
    #[test]
    fn writing_applies_upstream_limits() {
        let big_body = vec![0; MAX_FRAME_BODY + 1];
        let error = write_frame(&mut Vec::new(), &big_body, &[]).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        let big_payload = vec![0; MAX_PAYLOAD as usize + 1];
        let error = write_frame(&mut Vec::new(), &[0], &[&big_payload]).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        let half = vec![0; MAX_PAYLOAD as usize];
        let error = write_frame(&mut Vec::new(), &[0], &[&half, &half, &[0]]).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }

    #[test]
    fn oversize_body_is_refused() {
        let header = [0xff, 0xff, 0xff, 0x7f, 0, 0, 0, 0];
        let error = read_frame(&mut Cursor::new(header.to_vec())).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }
}
