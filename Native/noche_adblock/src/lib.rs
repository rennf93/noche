use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::Engine;
use std::ffi::{c_char, c_void, CStr, CString};

unsafe fn s<'a>(p: *const c_char) -> &'a str {
    if p.is_null() { "" } else { CStr::from_ptr(p).to_str().unwrap_or("") }
}

#[no_mangle]
pub unsafe extern "C" fn nab_engine_new(lists: *const *const c_char, n: usize) -> *mut c_void {
    let mut fs = FilterSet::new(false);
    for i in 0..n {
        fs.add_filter_list(s(*lists.add(i)).to_string(), ParseOptions::default());
    }
    Box::into_raw(Box::new(Engine::new_with_filter_set(fs))) as *mut c_void
}

#[no_mangle]
pub unsafe extern "C" fn nab_engine_free(e: *mut c_void) {
    if !e.is_null() { drop(Box::from_raw(e as *mut Engine)); }
}

#[no_mangle]
pub unsafe extern "C" fn nab_check(e: *const c_void, url: *const c_char, source_url: *const c_char, request_type: *const c_char) -> i32 {
    let e = &*(e as *const Engine);
    match Request::new(s(url), s(source_url), s(request_type), "GET") {
        Ok(r) => e.check_network_request(&r).should_block() as i32,
        Err(_) => 0,
    }
}

#[no_mangle]
pub unsafe extern "C" fn nab_cosmetic(e: *const c_void, url: *const c_char) -> *mut c_char {
    let e = &*(e as *const Engine);
    let r = e.url_cosmetic_resources(s(url));
    let j = serde_json::json!({
        "hide": r.hide_selectors, "procedural": r.procedural_actions,
        "exceptions": r.exceptions, "script": r.injected_script, "generichide": r.generichide,
    });
    CString::new(j.to_string()).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn nab_string_free(p: *mut c_char) {
    if !p.is_null() { drop(CString::from_raw(p)); }
}

/// Returns a malloc-style buffer owned by Rust; free with nab_bytes_free(ptr, len).
#[no_mangle]
pub unsafe extern "C" fn nab_serialize(e: *const c_void, out_len: *mut usize) -> *mut u8 {
    let v = (&*(e as *const Engine)).serialize().into_boxed_slice();
    *out_len = v.len();
    Box::into_raw(v) as *mut u8
}

#[no_mangle]
pub unsafe extern "C" fn nab_bytes_free(p: *mut u8, len: usize) {
    if !p.is_null() { drop(Box::from_raw(std::slice::from_raw_parts_mut(p, len))); }
}

#[no_mangle]
pub unsafe extern "C" fn nab_deserialize(buf: *const u8, len: usize) -> *mut c_void {
    let mut e = Engine::default();
    match e.deserialize(std::slice::from_raw_parts(buf, len)) {
        Ok(()) => Box::into_raw(Box::new(e)) as *mut c_void,
        Err(_) => std::ptr::null_mut(),
    }
}
