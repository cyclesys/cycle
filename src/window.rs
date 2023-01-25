use std::{ffi::c_void, mem, ptr::NonNull};

use windows::{
    core::{w, Error, Result, PCWSTR},
    Win32::{
        Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM},
        System::LibraryLoader::GetModuleHandleW,
        UI::WindowsAndMessaging::{
            AdjustWindowRect, CreateWindowExW, DefWindowProcW, GetWindowLongPtrW, LoadCursorW,
            PostQuitMessage, RegisterClassExW, SetWindowLongPtrW, ShowWindow, CREATESTRUCTW,
            CS_HREDRAW, CS_VREDRAW, CW_USEDEFAULT, GWLP_USERDATA, IDC_ARROW, SW_SHOW,
            WINDOW_EX_STYLE, WM_CREATE, WM_DESTROY, WM_PAINT, WNDCLASSEXW, WS_OVERLAPPEDWINDOW,
        },
    },
};

use crate::WindowDispatch;

pub struct Window {
    pub hwnd: HWND,
}

impl Window {
    pub fn create(dispatch: &WindowDispatch) -> Result<(Self, RECT)> {
        const WINDOW_CLASS_NAME: PCWSTR = w!("CycleWindowClass");
        const WINDOW_NAME: PCWSTR = w!("Cycle");

        let mut window_rect = RECT {
            left: 0,
            top: 0,
            right: 900,
            bottom: 600,
        };

        let hwnd = unsafe {
            let instance = GetModuleHandleW(None)?;

            {
                let cursor = LoadCursorW(None, IDC_ARROW)?;
                let window_class = WNDCLASSEXW {
                    cbSize: mem::size_of::<WNDCLASSEXW>() as u32,
                    style: CS_HREDRAW | CS_VREDRAW,
                    lpfnWndProc: Some(wnd_proc),
                    hInstance: instance,
                    hCursor: cursor,
                    lpszClassName: WINDOW_CLASS_NAME,
                    ..Default::default()
                };

                if RegisterClassExW(&window_class) == 0 {
                    return Err(Error::from_win32());
                }
            }

            let (width, height) = {
                AdjustWindowRect(&mut window_rect, WS_OVERLAPPEDWINDOW, false);
                (
                    window_rect.right - window_rect.left,
                    window_rect.bottom - window_rect.top,
                )
            };

            CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                WINDOW_CLASS_NAME,
                WINDOW_NAME,
                WS_OVERLAPPEDWINDOW,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                width,
                height,
                None,
                None,
                instance,
                Some(dispatch as *const WindowDispatch as *const c_void),
            )
        };

        Ok((Self { hwnd }, window_rect))
    }

    pub unsafe fn show(&self) {
        ShowWindow(self.hwnd, SW_SHOW);
    }
}

extern "system" fn wnd_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_CREATE => unsafe {
            let create_struct: &CREATESTRUCTW = mem::transmute(lparam);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, create_struct.lpCreateParams as isize);
        },

        WM_DESTROY => unsafe {
            PostQuitMessage(0);
        },

        _ => {
            let dispatch = unsafe {
                let user_data = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
                let Some(mut dispatch) = NonNull::<WindowDispatch>::new(user_data as *mut WindowDispatch) else {
                    return DefWindowProcW(hwnd, msg, wparam, lparam);
                };
                dispatch.as_mut()
            };

            match msg {
                WM_PAINT => {
                    dispatch.render();
                }

                _ => {
                    return unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) };
                }
            }
        }
    }

    LRESULT(0)
}
