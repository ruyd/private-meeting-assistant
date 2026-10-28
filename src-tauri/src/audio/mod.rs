pub mod mic;
pub mod resample;
#[cfg(target_os = "macos")]
pub mod system;

use serde::Serialize;

/// Everything downstream of capture works on 16 kHz mono f32 (what Whisper wants).
pub const TARGET_RATE: u32 = 16_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
pub enum Source {
    /// Local microphone — the user.
    Mic,
    /// System output — everyone else on the call.
    System,
}

impl Source {
    pub fn speaker(self) -> &'static str {
        match self {
            Source::Mic => "Me",
            Source::System => "Them",
        }
    }

    pub fn file_stem(self) -> &'static str {
        match self {
            Source::Mic => "me",
            Source::System => "them",
        }
    }
}

pub struct AudioChunk {
    pub source: Source,
    /// 16 kHz mono samples.
    pub samples: Vec<f32>,
}

/// A running capture; dropping it (or calling `stop`) ends the stream.
pub trait Capture: Send {
    fn stop(self: Box<Self>);
}
