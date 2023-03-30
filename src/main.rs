use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, PeekMessageW, TranslateMessage, MSG, PM_REMOVE, WM_QUIT,
};

use libcycle::render::Renderer;

mod launch;

mod window;
use window::Window;

pub struct WindowDispatch {
    renderer: Option<Renderer>,
    error: bool,
}

impl WindowDispatch {
    pub fn render(&mut self) {
        if let Some(renderer) = self.renderer.as_mut() {
            if renderer.render().is_err() {
                self.error = true;
            }
        };
    }
}

fn main() {
    let mut dispatch = WindowDispatch {
        renderer: None,
        error: false,
    };
    let Ok((window, window_rect)) = Window::create(&dispatch) else {
        return;
    };

    let Ok(renderer) = Renderer::create(window.hwnd, window_rect) else {
        return;
    };

    dispatch.renderer = Some(renderer);

    unsafe { window.show() };

    loop {
        let mut msg = MSG::default();
        unsafe {
            if PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).into() {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);

                if dispatch.error {
                    break;
                }

                if msg.message == WM_QUIT {
                    break;
                }
            }
        }
    }
}
