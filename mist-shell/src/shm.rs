use std::os::fd::BorrowedFd;

use wayland_client::protocol::wl_shm::WlShm;
use wayland_client::protocol::wl_shm_pool::WlShmPool;
use wayland_client::QueueHandle;

use crate::state::State;

pub fn shm_fd(size: usize) -> std::os::fd::RawFd {
    let name = std::ffi::CString::new("mist-pool").unwrap();
    let fd = unsafe { libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC) };
    assert!(fd >= 0, "memfd_create: {}", std::io::Error::last_os_error());
    unsafe { libc::ftruncate(fd, size as i64) };
    fd
}

pub fn setup_shm(shm: &WlShm, qh: &QueueHandle<State>, w: i32, h: i32) -> (memmap2::MmapMut, WlShmPool, i32, i32) {
    let stride = w * 4;
    let buf_size = stride * h;
    let pool_size = (buf_size * 2) as usize;
    let fd = shm_fd(pool_size);
    let mmap = unsafe { memmap2::MmapMut::map_mut(fd) }.expect("mmap");
    let pool = shm.create_pool(unsafe { BorrowedFd::borrow_raw(fd) }, pool_size as i32, qh, ());
    unsafe { libc::close(fd) };
    (mmap, pool, stride, buf_size)
}
