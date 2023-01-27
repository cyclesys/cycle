use windows::{
    core::Error as WindowsError,
    Win32::{
        Foundation::{HANDLE, WAIT_ABANDONED, WAIT_FAILED, WAIT_OBJECT_0, WAIT_TIMEOUT},
        System::{
            Threading::{ResetEvent, WaitForSingleObject},
            WindowsProgramming::INFINITE,
        },
    },
};

pub enum Error {
    ChannelWaitFailed(Option<WindowsError>),
    ChannelTerminated,
    Windows(WindowsError),
}

pub type Result<T> = std::result::Result<T, Error>;

enum SyncState {
    Idle,
    Locked,
    Unlocked,
    End,
}

pub(super) struct ChannelSync {
    mutex: HANDLE,
    wait_event: HANDLE,
    signal_event: HANDLE,
    state: SyncState,
}

impl ChannelSync {
    pub fn new(mutex: HANDLE, wait_event: HANDLE, signal_event: HANDLE) -> Self {
        Self {
            mutex,
            wait_event,
            signal_event,
            state: SyncState::Idle,
        }
    }

    fn reset_to_idle(&mut self) -> Result<()> {
        unsafe {
            if ResetEvent(self.wait_event) == false {
                Err(Error::Windows(WindowsError::from_win32()))
            } else {
                self.state = SyncState::Idle;
                Ok(())
            }
        }
    }
}

impl ChannelSync {
    pub fn peek(&mut self) -> Result<bool> {
        match self.state {
            SyncState::Idle => self.peek_mutex(),
            SyncState::Locked => self.peek_wait_event(),
            SyncState::Unlocked => Ok(true),
            SyncState::End => {
                self.reset_to_idle()?;
                self.peek_mutex()
            }
        }
    }

    fn peek_mutex(&mut self) -> Result<bool> {
        unsafe {
            match WaitForSingleObject(self.mutex, 0) {
                WAIT_OBJECT_0 => {
                    ResetEvent(self.signal_event);
                    self.state = SyncState::Unlocked;
                    Ok(true)
                }
                WAIT_TIMEOUT => {
                    self.state = SyncState::Locked;
                    Ok(false)
                }
                WAIT_ABANDONED => Err(Error::ChannelTerminated),
                WAIT_FAILED => Err(Error::ChannelWaitFailed(Some(WindowsError::from_win32()))),
                _ => unreachable!(),
            }
        }
    }

    fn peek_wait_event(&mut self) -> Result<bool> {
        unsafe {
            match WaitForSingleObject(self.wait_event, 0) {
                WAIT_OBJECT_0 => {
                    self.state = SyncState::Unlocked;
                    Ok(true)
                }
                WAIT_TIMEOUT => {
                    self.state = SyncState::Locked;
                    Ok(false)
                }
                WAIT_ABANDONED => Err(Error::ChannelTerminated),
                WAIT_FAILED => Err(Error::ChannelWaitFailed(Some(WindowsError::from_win32()))),
                _ => unreachable!(),
            }
        }
    }
}

impl ChannelSync {
    pub fn wait(&mut self) -> Result<()> {
        match self.state {
            SyncState::Idle => self.wait_from_idle(),
            SyncState::Locked => self.wait_on_event(),
            SyncState::Unlocked => Ok(()),
            SyncState::End => {
                self.reset_to_idle()?;
                self.wait_from_idle()
            }
        }
    }

    fn wait_from_idle(&mut self) -> Result<()> {
        if self.peek_mutex()? {
            Ok(())
        } else {
            self.state = SyncState::Locked;
            self.wait_on_event()
        }
    }

    fn wait_on_event(&mut self) -> Result<()> {
        match unsafe { WaitForSingleObject(self.wait_event, INFINITE) } {
            WAIT_OBJECT_0 => {
                self.state = SyncState::Unlocked;
                Ok(())
            }
            WAIT_TIMEOUT => Err(Error::ChannelWaitFailed(None)),
            WAIT_ABANDONED => Err(Error::ChannelTerminated),
            WAIT_FAILED => Err(Error::ChannelWaitFailed(Some(WindowsError::from_win32()))),
            _ => unreachable!(),
        }
    }
}

impl ChannelSync {
    pub fn wait_for(&mut self, milliseconds: u32) -> Result<bool> {
        match self.state {
            SyncState::Idle => self.wait_from_idle_for(milliseconds),
            SyncState::Locked => self.wait_on_event_for(milliseconds),
            SyncState::Unlocked => Ok(true),
            SyncState::End => {
                self.reset_to_idle()?;
                self.wait_from_idle_for(milliseconds)
            }
        }
    }

    fn wait_from_idle_for(&mut self, milliseconds: u32) -> Result<bool> {
        if self.peek_mutex()? {
            Ok(true)
        } else {
            self.state = SyncState::Locked;
            self.wait_on_event_for(milliseconds)
        }
    }

    fn wait_on_event_for(&mut self, milliseconds: u32) -> Result<bool> {
        match unsafe { WaitForSingleObject(self.wait_event, milliseconds) } {
            WAIT_OBJECT_0 => {
                self.state = SyncState::Unlocked;
                Ok(true)
            }
            WAIT_TIMEOUT => {
                self.state = SyncState::Locked;
                Ok(false)
            }
            WAIT_ABANDONED => Err(Error::ChannelTerminated),
            WAIT_FAILED => Err(Error::ChannelWaitFailed(Some(WindowsError::from_win32()))),
            _ => unreachable!(),
        }
    }
}
