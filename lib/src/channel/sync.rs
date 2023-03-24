use windows::Win32::{
    Foundation::{BOOL, HANDLE, WAIT_ABANDONED, WAIT_FAILED, WAIT_OBJECT_0, WAIT_TIMEOUT},
    System::{
        Threading::{ResetEvent, SetEvent, WaitForSingleObject},
        WindowsProgramming::INFINITE,
    },
};

use super::{Error, Result, WindowsError};

pub struct ChannelSync {
    wait_event: HANDLE,
    signal_event: HANDLE,
}

impl ChannelSync {
    pub fn wait_event(&self) -> HANDLE {
        self.wait_event
    }

    pub fn signal_event(&self) -> HANDLE {
        self.signal_event
    }
}

impl ChannelSync {
    pub fn new(wait_event: HANDLE, signal_event: HANDLE) -> Self {
        Self {
            wait_event,
            signal_event,
        }
    }

    pub fn wait(&self) -> Result<()> {
        match unsafe { WaitForSingleObject(self.wait_event, INFINITE) } {
            WAIT_OBJECT_0 => Ok(()),
            WAIT_TIMEOUT => Err(Error::ChannelWaitFailed(None)),
            WAIT_ABANDONED => Err(Error::ChannelTerminated),
            WAIT_FAILED => Err(Error::ChannelWaitFailed(Some(WindowsError::from_win32()))),
            _ => unreachable!(),
        }
    }

    pub fn signal(&self) -> Result<()> {
        fn check_success(result: BOOL) -> Result<()> {
            if result == false {
                Err(Error::ChannelSignalFailed(WindowsError::from_win32()))
            } else {
                Ok(())
            }
        }
        check_success(unsafe { ResetEvent(self.wait_event) })?;
        check_success(unsafe { SetEvent(self.signal_event) })?;

        Ok(())
    }
}
