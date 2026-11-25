/* Original native-only CLI adapter. SPDX-License-Identifier: BSD-2-Clause */
#if !defined(_WIN32) && !defined(__linux__) && !defined(__APPLE__)
#error "MoonBSDiff CLI adapter supports Windows, Linux, and macOS only"
#endif
#ifndef _WIN32
#ifdef __linux__
#define _GNU_SOURCE
#elif defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#define _FILE_OFFSET_BITS 64
#endif
#include "moonbit.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#ifdef MBSD_IO_TEST
#include <time.h>
#endif
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stddef.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <strings.h>
#include <sys/stat.h>
#include <dirent.h>
#ifdef __linux__
#include <sys/ioctl.h>
#include <sys/random.h>
#include <sys/vfs.h>
#include <linux/fs.h>
#include <linux/magic.h>
#ifndef FS_CASEFOLD_FL
#define FS_CASEFOLD_FL 0x40000000
#endif
#endif
#ifdef __APPLE__
#include <crt_externs.h>
#endif
#endif

#ifdef _WIN32
static int stream_populate(HANDLE writer);
#else
static int stream_populate(int writer);
#endif

static int stream_stopped;
static int stream_prepare_commit(void);
static void stream_mark_published(void);
/* The last synchronous delivery may have published before reporting an error. */
static int delivery_committed;
static void mark_delivery(moonbit_bytes_t data) {
  delivery_committed=1;
  if(!data) stream_mark_published();
}
static char problem[512];
static void annotate_delivered_problem(void) {
  if(delivery_committed && problem[0] && strncmp(problem,"output already delivered;",25)!=0) {
    char original[512];memcpy(original,problem,sizeof(original));
    snprintf(problem,sizeof(problem),"output already delivered; %.475s",original);
  }
}
/* A private source snapshot enables these fault points at compile time. */
#ifdef MBSD_IO_TEST
#define IO_TEST(...) __VA_ARGS__
static int fault;
#else
#define IO_TEST(...)
#endif
#if defined(_WIN32) && defined(MBSD_IO_TEST)
static unsigned sequence;
#endif
static void fail(const char *op, unsigned long code) {
  if (!problem[0]) snprintf(problem,sizeof(problem),"%s (OS error %lu)",op,code);
  else if(stream_stopped) { size_t n=strlen(problem); if(n<sizeof(problem)-1) snprintf(problem+n,sizeof(problem)-n,"; %s (OS error %lu)",op,code); }
}
static void limit_fail(const char *op, int cap) {
  if (!problem[0]) snprintf(problem,sizeof(problem),"%s: byte limit %d exceeded",op,cap);
}
static moonbit_bytes_t bytes(const void *p, size_t n) {
  moonbit_bytes_t result=moonbit_make_bytes_raw((int32_t)n);
  if(n) memcpy(result,p,n);
  return result;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mbsd_io_error(void) { return bytes(problem,strlen(problem)); }
MOONBIT_FFI_EXPORT int32_t mbsd_io_failed(void) { return problem[0]!=0; }
MOONBIT_FFI_EXPORT int32_t mbsd_delivery_committed(void) { return delivery_committed; }
MOONBIT_FFI_EXPORT void mbsd_stderr(moonbit_bytes_t data) {
  size_t n=Moonbit_array_length(data),at=0;
  while(at<n) { size_t k=fwrite(data+at,1,n-at,stderr); if(!k) break; at+=k; }
  fflush(stderr);
}
#ifdef _WIN32
static int windows_write(HANDLE file,const void *data,DWORD requested,DWORD *done,const char *op) {
  BOOL written;
  IO_TEST(if(fault==10) {
    *done=0;
    SetLastError(ERROR_ACCESS_DENIED); /* A successful call need not clear it. */
    written=TRUE;
  } else)
  written=WriteFile(file,data,requested,done,NULL);
  if(!written) {
    DWORD error=GetLastError();
    fail(op,error);
    return 0;
  }
  if(!*done) {
    fail("write made no progress",ERROR_WRITE_FAULT);
    return 0;
  }
  return 1;
}
static wchar_t *wide(const char *s) {
  int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s,-1,NULL,0);
  if(n<=0) { fail("UTF-8 path conversion",GetLastError()); return NULL; }
  if(n>32768) { fail("UTF-8 path too long",ERROR_FILENAME_EXCED_RANGE); return NULL; }
  wchar_t *p=malloc((size_t)n*sizeof(wchar_t));
  if(!p) { fail("path allocation",ERROR_NOT_ENOUGH_MEMORY); return NULL; }
  if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s,-1,p,n)) { DWORD e=GetLastError(); free(p); fail("UTF-8 path conversion",e); return NULL; }
  return p;
}
static int valid_utf16(const wchar_t *s) {
  for(size_t i=0;s[i];i++) {
    uint16_t w=(uint16_t)s[i];
    if(w>=0xD800u && w<=0xDBFFu) {
      uint16_t next=(uint16_t)s[i+1];
      if(next<0xDC00u || next>0xDFFFu) return 0;
      i++;
    } else if(w>=0xDC00u && w<=0xDFFFu) return 0;
  }
  return 1;
}
#ifndef LOAD_LIBRARY_SEARCH_SYSTEM32
#define LOAD_LIBRARY_SEARCH_SYSTEM32 0x00000800
#endif
static int fill_csprng(unsigned char *out,size_t len) {
  if(!len) return 1;
  typedef LONG (WINAPI *bcrypt_random)(void*,unsigned char*,ULONG,ULONG);
  HMODULE dll=LoadLibraryExW(L"bcrypt.dll",NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
  if(!dll) {
    DWORD e=GetLastError();
    SecureZeroMemory(out,len);
    fail("load cryptographic random provider",e);
    return 0;
  }
  bcrypt_random gen=(bcrypt_random)GetProcAddress(dll,"BCryptGenRandom");
  if(!gen) {
    DWORD e=GetLastError();
    FreeLibrary(dll);
    SecureZeroMemory(out,len);
    fail("resolve cryptographic random provider",e);
    return 0;
  }
  size_t at=0;
  while(at<len) {
    size_t rem=len-at;
    ULONG chunk=rem>0xffffffffUL?0xffffffffUL:(ULONG)rem;
    LONG status=gen(NULL,out+at,chunk,0x00000002UL);
    if(status!=0) {
      FreeLibrary(dll);
      SecureZeroMemory(out,len);
      fail("generate cryptographic random bytes",(unsigned long)(uint32_t)status);
      return 0;
    }
    at+=chunk;
  }
  FreeLibrary(dll);
  return 1;
}
static int win_random_hex(wchar_t out[33]) {
  unsigned char token[16]={0};
  if(!fill_csprng(token,sizeof(token))) return 0;
  static const wchar_t hex[]=L"0123456789abcdef";
  for(size_t i=0;i<16;i++) { out[i*2]=hex[token[i]>>4]; out[i*2+1]=hex[token[i]&15]; }
  out[32]=0;
  return 1;
}
static int win_is_ascii_alpha(wchar_t c) {
  return (c>=L'A' && c<=L'Z') || (c>=L'a' && c<=L'z');
}
static int win_validate_output_path(const wchar_t *raw) {
  size_t len=wcslen(raw);
  if(!len) { fail("invalid output name",ERROR_INVALID_NAME); return 0; }
  if(raw[len-1]==L'\\' || raw[len-1]==L'/') { fail("invalid output name",ERROR_INVALID_NAME); return 0; }
  if((len==3 || (len>=4 && (raw[3]==L'\\' || raw[3]==L'/'))) &&
     (raw[0]==L'\\' || raw[0]==L'/') && (raw[1]==L'\\' || raw[1]==L'/') && raw[2]==L'.') {
    fail("Win32 device namespace paths (\\\\.\\) are unsupported",ERROR_INVALID_NAME);
    return 0;
  }
  int extended=(len>=4 && (raw[0]==L'\\' || raw[0]==L'/') && (raw[1]==L'\\' || raw[1]==L'/') &&
                raw[2]==L'?' && (raw[3]==L'\\' || raw[3]==L'/'));
  if(extended && wcschr(raw,L'/')) { fail("forward slashes are unsupported in extended paths",ERROR_INVALID_NAME); return 0; }
  const wchar_t *leaf=raw;
  for(const wchar_t *q=raw;*q;q++) if(*q==L'\\' || *q==L'/') leaf=q+1;
  if(!*leaf || wcscmp(leaf,L".")==0 || wcscmp(leaf,L"..")==0) { fail("invalid output name",ERROR_INVALID_NAME); return 0; }
  const wchar_t *colon_scan=leaf;
  if(leaf==raw && win_is_ascii_alpha(raw[0]) && raw[1]==L':') {
    if(!raw[2]) { fail("invalid output name",ERROR_INVALID_NAME); return 0; }
    colon_scan=raw+2;
  }
  if(wcschr(colon_scan,L':')) { fail("alternate data streams are unsupported",ERROR_INVALID_NAME); return 0; }
  size_t llen=wcslen(leaf);
  if(llen && (leaf[llen-1]==L'.' || leaf[llen-1]==L' ')) {
    fail(extended?"extended path trailing dot or space is unsupported"
                 :"trailing dot or space in output path is unsupported",ERROR_INVALID_NAME);
    return 0;
  }
  size_t scan_start=0;
  if(extended) {
    scan_start=4;
    if(len>=8 && (raw[4]==L'U' || raw[4]==L'u') && (raw[5]==L'N' || raw[5]==L'n') &&
       (raw[6]==L'C' || raw[6]==L'c') && raw[7]==L'\\') scan_start=8;
  } else if(len>=2 && (raw[0]==L'\\' || raw[0]==L'/') && (raw[1]==L'\\' || raw[1]==L'/')) {
    scan_start=2;
  }
  size_t seg_start=scan_start;
  for(size_t i=scan_start;i<=len;i++) {
    if(i<len && raw[i]!=L'\\' && raw[i]!=L'/') continue;
    size_t slen=i-seg_start;
    if(slen>0) {
      int is_dot=(slen==1 && raw[seg_start]==L'.');
      int is_dotdot=(slen==2 && raw[seg_start]==L'.' && raw[seg_start+1]==L'.');
      int is_drive=(seg_start==scan_start && slen==2 && win_is_ascii_alpha(raw[seg_start]) && raw[seg_start+1]==L':');
      if(!is_dot && !is_dotdot && !is_drive) {
        wchar_t tail=raw[i-1];
        if(tail==L'.' || tail==L' ') {
          fail(extended?"extended path trailing dot or space is unsupported"
                       :"trailing dot or space in output path is unsupported",ERROR_INVALID_NAME);
          return 0;
        }
      }
    }
    seg_start=i+1;
  }
  return 1;
}
#else
#ifdef __linux__
static int linux_argc;
static char **linux_argv;
__attribute__((constructor)) static void mbsd_capture_argv(int argc,char **argv,char **envp) {
  (void)envp;
  if(argc>0 && argv) { linux_argc=argc; linux_argv=argv; }
}
static int fill_csprng(unsigned char *out,size_t len) {
  size_t at=0;
  while(at<len) {
    ssize_t n=getrandom(out+at,len-at,0);
    if(n<0 && errno==EINTR) continue;
    if(n<=0) {
      int e=n<0?errno:EIO;
      volatile unsigned char *vp=out;
      for(size_t i=0;i<len;i++) vp[i]=0;
      fail("generate cryptographic random bytes",(unsigned long)e);
      return 0;
    }
    at+=(size_t)n;
  }
  return 1;
}
#elif defined(__APPLE__)
static int fill_csprng(unsigned char *out,size_t len) {
  if(len>0) arc4random_buf(out,len);
  return 1;
}
#endif
static int valid_utf8(const unsigned char *s,size_t n) {
  size_t i=0;
  while(i<n) {
    unsigned char c=s[i];
    if(c<0x80u) { i++; }
    else if(c>=0xC2u && c<=0xDFu) {
      if(i+1>=n || (s[i+1]&0xC0u)!=0x80u) return 0;
      i+=2;
    } else if(c==0xE0u) {
      if(i+2>=n || s[i+1]<0xA0u || s[i+1]>0xBFu || (s[i+2]&0xC0u)!=0x80u) return 0;
      i+=3;
    } else if((c>=0xE1u && c<=0xECu) || (c>=0xEEu && c<=0xEFu)) {
      if(i+2>=n || (s[i+1]&0xC0u)!=0x80u || (s[i+2]&0xC0u)!=0x80u) return 0;
      i+=3;
    } else if(c==0xEDu) {
      if(i+2>=n || s[i+1]<0x80u || s[i+1]>0x9Fu || (s[i+2]&0xC0u)!=0x80u) return 0;
      i+=3;
    } else if(c==0xF0u) {
      if(i+3>=n || s[i+1]<0x90u || s[i+1]>0xBFu || (s[i+2]&0xC0u)!=0x80u || (s[i+3]&0xC0u)!=0x80u) return 0;
      i+=4;
    } else if(c>=0xF1u && c<=0xF3u) {
      if(i+3>=n || (s[i+1]&0xC0u)!=0x80u || (s[i+2]&0xC0u)!=0x80u || (s[i+3]&0xC0u)!=0x80u) return 0;
      i+=4;
    } else if(c==0xF4u) {
      if(i+3>=n || s[i+1]<0x80u || s[i+1]>0x8Fu || (s[i+2]&0xC0u)!=0x80u || (s[i+3]&0xC0u)!=0x80u) return 0;
      i+=4;
    } else return 0;
  }
  return 1;
}
#endif
MOONBIT_FFI_EXPORT int32_t mbsd_random_bytes(moonbit_bytes_t out) {
  problem[0]=0;
  if(!out) { fail("invalid random buffer",EINVAL); return 0; }
  int32_t n=Moonbit_array_length(out);
  if(n<0) { fail("invalid random buffer",EINVAL); return 0; }
  if(n==0) return 1;
  return fill_csprng((unsigned char *)out,(size_t)n);
}
/* Windows arguments must not depend on the runtime's MinGW ANSI fallback. */
#ifdef _WIN32
static LPWSTR *cli_argv;
static int cli_argc;
#endif
MOONBIT_FFI_EXPORT int32_t mbsd_arg_count(void) {
  problem[0]=0;
#ifdef _WIN32
  if(cli_argv) { LocalFree(cli_argv); cli_argv=NULL; cli_argc=0; }
  typedef LPWSTR *(WINAPI *parse_args)(LPCWSTR,int*);
  HMODULE dll=LoadLibraryExW(L"shell32.dll",NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
  if(!dll) { fail("load command-line parser",GetLastError()); return -2; }
  parse_args parse=(parse_args)GetProcAddress(dll,"CommandLineToArgvW");
  if(parse) cli_argv=parse(GetCommandLineW(),&cli_argc);
  if(!cli_argv) fail("parse Unicode command line",GetLastError());
  FreeLibrary(dll);
  if(!cli_argv) return -2;
  for(int i=0;i<cli_argc;i++) {
    if(!valid_utf16(cli_argv[i])) {
      LocalFree(cli_argv); cli_argv=NULL; cli_argc=0;
      fail("unpaired UTF-16 surrogate in command-line argument",ERROR_NO_UNICODE_TRANSLATION);
      return -3;
    }
  }
  if(cli_argc<=0) { LocalFree(cli_argv); cli_argv=NULL; cli_argc=0; return 0; }
  return cli_argc;
#elif defined(__APPLE__)
  int *argc_ptr=_NSGetArgc();
  char ***argv_ptr=_NSGetArgv();
  int argc=argc_ptr?*argc_ptr:0;
  char **argv=argv_ptr?*argv_ptr:NULL;
  if(argc>0 && argv) {
    for(int i=0;i<argc;i++) {
      if(argv[i] && !valid_utf8((const unsigned char*)argv[i],strlen(argv[i]))) {
        fail("command-line arguments must be valid UTF-8",EILSEQ);
        return -3;
      }
    }
  }
  return -1;
#else
  if(linux_argc>0 && linux_argv) {
    for(int i=0;i<linux_argc;i++) {
      if(linux_argv[i] && !valid_utf8((const unsigned char*)linux_argv[i],strlen(linux_argv[i]))) {
        fail("command-line arguments must be valid UTF-8",EILSEQ);
        return -3;
      }
    }
  } else {
    int fd=open("/proc/self/cmdline",O_RDONLY|O_CLOEXEC);
    if(fd>=0) {
      unsigned char *buf=NULL; size_t used=0,cap=0;
      for(;;) {
        unsigned char tmp[4096]; ssize_t got=read(fd,tmp,sizeof(tmp));
        if(got<0 && errno==EINTR) continue;
        if(got<=0) break;
        if(used+(size_t)got>cap) {
          size_t next=cap?cap*2:4096; while(next<used+(size_t)got) next*=2;
          unsigned char *grown=realloc(buf,next);
          if(!grown) { free(buf); close(fd); fail("read command line",ENOMEM); return -2; }
          buf=grown; cap=next;
        }
        memcpy(buf+used,tmp,(size_t)got); used+=(size_t)got;
      }
      close(fd);
      if(buf) {
        size_t pos=0;
        while(pos<used) {
          size_t end=pos; while(end<used && buf[end]) end++;
          if(!valid_utf8(buf+pos,end-pos)) {
            free(buf);
            fail("command-line arguments must be valid UTF-8",EILSEQ);
            return -3;
          }
          pos=end+1;
        }
        free(buf);
      }
    }
  }
  return -1;
#endif
}
MOONBIT_FFI_EXPORT moonbit_string_t mbsd_arg(int32_t i) {
#ifdef _WIN32
  if(!cli_argv || i<0 || i>=cli_argc) return moonbit_make_string(0,0);
  int n=(int)wcslen(cli_argv[i]);
  moonbit_string_t result=moonbit_make_string_raw(n);
  memcpy(result,cli_argv[i],(size_t)n*sizeof(uint16_t));
  if(i==cli_argc-1) { LocalFree(cli_argv); cli_argv=NULL; cli_argc=0; }
  return result;
#else
  (void)i; return moonbit_make_string(0,0);
#endif
}

IO_TEST(static int test_put(const char *name,const char *data,int n,int append);)

MOONBIT_FFI_EXPORT moonbit_bytes_t mbsd_read(moonbit_bytes_t name,int32_t cap) {
  problem[0]=0;
  unsigned char *buffer=NULL; size_t used=0,capacity=0;
  if(cap<0) { fail("negative read cap",EINVAL); return bytes(NULL,0); }
#ifdef _WIN32
  wchar_t *path=wide((char*)name); if(!path) return bytes(NULL,0);
  HANDLE f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
  DWORD open_err=GetLastError();
  free(path);
  if(f==INVALID_HANDLE_VALUE) { fail("open input",open_err); return bytes(NULL,0); }
  LARGE_INTEGER size;
  DWORD ftype=GetFileType(f);
  if(ftype!=FILE_TYPE_DISK) {
    DWORD type_err=(ftype==FILE_TYPE_UNKNOWN)?GetLastError():ERROR_INVALID_FUNCTION;
    fail("input must be a regular disk file",type_err?type_err:ERROR_INVALID_FUNCTION);
  }
  else if(!GetFileSizeEx(f,&size)) fail("stat regular input",GetLastError());
  else if(IO_TEST(fault!=8 &&) size.QuadPart>cap) limit_fail("input size",cap);
#else
  int f=open((char*)name,O_RDONLY|O_CLOEXEC|O_NONBLOCK);
  if(f<0) { fail("open input",errno); return bytes(NULL,0); }
  struct stat st;
  if(fstat(f,&st)<0) fail("stat input",errno);
  else if(!S_ISREG(st.st_mode)) fail("input must be a regular file",EINVAL);
  else if(IO_TEST(fault!=8 &&) st.st_size>cap) limit_fail("input size",cap);
#endif
  IO_TEST(if(!problem[0] && fault==3 && !test_put((char*)name,"BC",2,1)) fail("test growth",EIO);)
  while(!problem[0]) {
    unsigned char chunk[4096];
    size_t room=(size_t)cap-used;
    size_t request=room<sizeof(chunk)?room+1:sizeof(chunk);
    size_t count;
#ifdef _WIN32
    DWORD got=0;
    if(!ReadFile(f,chunk,(DWORD)request,&got,NULL)) {
      DWORD error=GetLastError();
      fail("read input",error);break;
    }
    count=got;
#else
    ssize_t got=read(f,chunk,request);
    if(got<0) { if(errno==EINTR) continue; fail("read input",errno); break; }
    count=(size_t)got;
#endif
    if(!count) break;
    if(count>room) { limit_fail("read limit",cap); break; }
    size_t wanted=used+count; /* <= cap proven before arithmetic/growth */
    if(wanted>capacity) {
      size_t next=capacity ? capacity : ((size_t)cap<4096?(size_t)cap:4096);
      while(next<wanted) next=next>(size_t)cap/2?(size_t)cap:next*2;
      unsigned char *grown=realloc(buffer,next);
      if(!grown) { fail("read buffer allocation",ENOMEM); break; }
      buffer=grown; capacity=next;
    }
    memcpy(buffer+used,chunk,count); used=wanted;
  }
#ifdef _WIN32
  if(!CloseHandle(f)) fail("close input",GetLastError());
#else
  /* Do not retry close after EINTR: Linux has already released the descriptor. */
  if(close(f)<0) fail("close input",errno);
#endif
  IO_TEST(if(fault==7) fail("injected close input",EIO);)
  moonbit_bytes_t result=problem[0]?bytes(NULL,0):bytes(buffer,used);
  free(buffer); return result;
}

MOONBIT_FFI_EXPORT int32_t mbsd_input_check(moonbit_bytes_t name) {
  problem[0]=0;
#ifdef _WIN32
  wchar_t *path=wide((char*)name); if(!path) return 0;
  HANDLE f=CreateFileW(path,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
  DWORD open_err=GetLastError();
  free(path);
  if(f==INVALID_HANDLE_VALUE) { fail("open input",open_err); return 0; }
  LARGE_INTEGER size;
  DWORD ftype=GetFileType(f);
  if(ftype!=FILE_TYPE_DISK) {
    DWORD type_err=(ftype==FILE_TYPE_UNKNOWN)?GetLastError():ERROR_INVALID_FUNCTION;
    fail("input must be a regular disk file",type_err?type_err:ERROR_INVALID_FUNCTION);
  } else if(!GetFileSizeEx(f,&size)) fail("stat regular input",GetLastError());
  if(!CloseHandle(f)) fail("close input",GetLastError());
#else
  int f=open((char*)name,O_RDONLY|O_CLOEXEC|O_NONBLOCK);
  if(f<0) { fail("open input",errno); return 0; }
  struct stat st;
  if(fstat(f,&st)<0) fail("stat input",errno);
  else if(!S_ISREG(st.st_mode)) fail("input must be a regular file",EINVAL);
  if(close(f)<0) fail("close input",errno);
#endif
  return !problem[0];
}

MOONBIT_FFI_EXPORT int32_t mbsd_input_alias_check(moonbit_bytes_t input,moonbit_bytes_t out) {
  problem[0]=0;
#ifdef _WIN32
  wchar_t *p=wide((char*)out); if(!p) return 0;
  if(!win_validate_output_path(p)) { free(p); return 0; }
  DWORD attrs=GetFileAttributesW(p);
  if(attrs!=INVALID_FILE_ATTRIBUTES) {
    HANDLE target=CreateFileW(p,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
    BY_HANDLE_FILE_INFORMATION ti;
    int valid=target!=INVALID_HANDLE_VALUE && GetFileInformationByHandle(target,&ti);
    if(valid) {
      wchar_t *q=wide((char*)input);
      if(q) {
        HANDLE source=CreateFileW(q,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
        free(q);
        if(source!=INVALID_HANDLE_VALUE) {
          BY_HANDLE_FILE_INFORMATION si;
          if(GetFileInformationByHandle(source,&si) && si.dwVolumeSerialNumber==ti.dwVolumeSerialNumber && si.nFileIndexHigh==ti.nFileIndexHigh && si.nFileIndexLow==ti.nFileIndexLow) fail("output is the same file as an input",ERROR_ALREADY_EXISTS);
          if(!CloseHandle(source)) fail("close identity input",GetLastError());
        }
      }
    }
    if(target!=INVALID_HANDLE_VALUE && !CloseHandle(target)) fail("close identity output",GetLastError());
  }
  free(p);
#else
  struct stat t,s;
  if(stat((char*)out,&t)==0 && stat((char*)input,&s)==0 && t.st_dev==s.st_dev && t.st_ino==s.st_ino)
    fail("output is the same file as an input",EEXIST);
#endif
  return !problem[0];
}

MOONBIT_FFI_EXPORT int32_t mbsd_output_check(moonbit_bytes_t a,moonbit_bytes_t b,moonbit_bytes_t out) {
  problem[0]=0;
#ifdef _WIN32
  wchar_t *p=wide((char*)out); if(!p) return 0;
  if(!win_validate_output_path(p)) { free(p); return 0; }
  DWORD attrs=GetFileAttributesW(p);
  if(attrs!=INVALID_FILE_ATTRIBUTES) {
    HANDLE target=CreateFileW(p,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
    BY_HANDLE_FILE_INFORMATION ti;
    int valid=target!=INVALID_HANDLE_VALUE && GetFileInformationByHandle(target,&ti);
    moonbit_bytes_t inputs[2]={a,b};
    for(int i=0;i<2 && valid;i++) {
      wchar_t *q=wide((char*)inputs[i]);
      if(q) {
        HANDLE source=CreateFileW(q,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL); free(q);
        if(source!=INVALID_HANDLE_VALUE) {
          BY_HANDLE_FILE_INFORMATION si;
          if(GetFileInformationByHandle(source,&si) && si.dwVolumeSerialNumber==ti.dwVolumeSerialNumber && si.nFileIndexHigh==ti.nFileIndexHigh && si.nFileIndexLow==ti.nFileIndexLow) fail("output is the same file as an input",ERROR_ALREADY_EXISTS);
          if(!CloseHandle(source)) fail("close identity input",GetLastError());
        }
      }
    }
    if(target!=INVALID_HANDLE_VALUE && !CloseHandle(target)) fail("close identity output",GetLastError());
    fail("output already exists (including links/directories)",ERROR_ALREADY_EXISTS);
  } else { DWORD e=GetLastError(); if(e!=ERROR_FILE_NOT_FOUND && e!=ERROR_PATH_NOT_FOUND) fail("inspect output",e); }
  free(p);
#else
  const char *out_path=(const char *)out;
  size_t out_len=strlen(out_path);
  if(!out_len || out_path[out_len-1]=='/') {
    fail("invalid output name",EINVAL);
    return 0;
  }
  struct stat t,l;
  if(lstat(out_path,&l)==0) {
    if(stat(out_path,&t)==0) {
      moonbit_bytes_t inputs[2]={a,b};
      for(int i=0;i<2;i++) { struct stat s; if(stat((char*)inputs[i],&s)==0 && t.st_dev==s.st_dev && t.st_ino==s.st_ino) fail("output is the same file as an input",EEXIST); }
    }
    fail("output already exists (including links/directories)",EEXIST);
  } else if(errno!=ENOENT) fail("inspect output",errno);
#endif
  return !problem[0];
}

/* Read-only identity preflight for two not-yet-created outputs. Existing
 * targets/inputs are rejected separately by mbsd_output_check. Parent handles
 * follow directory aliases. No write probe or destination reservation is made. */
#ifdef _WIN32
static wchar_t win_ascii_upper(wchar_t c) { return (c>=L'a' && c<=L'z')?(wchar_t)(c-L'a'+L'A'):c; }
static int win_is_short_alias_one(const wchar_t *short_name,const wchar_t *long_name) {
  const wchar_t *tilde=wcschr(short_name,L'~');
  if(!tilde || tilde==short_name) return 0;
  size_t prefix_len=(size_t)(tilde-short_name);
  if(prefix_len>6) return 0;
  const wchar_t *q=tilde+1;
  if(*q<L'1' || *q>L'9') return 0;
  while(*q>=L'0' && *q<=L'9') q++;
  if((size_t)(q-short_name)>8 || (*q && *q!=L'.')) return 0;
  const wchar_t *short_ext=(*q==L'.')?(q+1):L"";
  size_t short_ext_len=wcslen(short_ext);
  if(short_ext_len>3 || wcschr(short_ext,L'.')) return 0;
  const wchar_t *long_dot=wcsrchr(long_name,L'.');
  const wchar_t *long_ext=long_dot?(long_dot+1):L"";
  size_t long_base_len=long_dot?(size_t)(long_dot-long_name):wcslen(long_name);
  int long_needs_short=(long_base_len>8 || wcslen(long_ext)>3 || (long_dot && wcschr(long_name,L'.')!=long_dot) || wcschr(long_name,L' ')!=NULL);
  if(!long_needs_short) return 0;
  /* Strip spaces/dots from long base as NTFS does when synthesizing 8.3 prefixes. */
  size_t matched=0;
  for(size_t i=0;i<long_base_len && matched<prefix_len;i++) {
    wchar_t c=long_name[i];
    if(c==L' ' || c==L'.') continue;
    if(win_ascii_upper(c)!=win_ascii_upper(short_name[matched])) return 0;
    matched++;
  }
  if(matched!=prefix_len) return 0;
  size_t ext_matched=0;
  for(const wchar_t *e=long_ext;*e && ext_matched<3;e++) {
    if(*e==L' ') continue;
    if(ext_matched>=short_ext_len || win_ascii_upper(*e)!=win_ascii_upper(short_ext[ext_matched])) return 0;
    ext_matched++;
  }
  return ext_matched==short_ext_len;
}
static int win_maybe_short_name_alias(const wchar_t *a,const wchar_t *b) {
  return win_is_short_alias_one(a,b) || win_is_short_alias_one(b,a);
}
static HANDLE pair_parent(moonbit_bytes_t name,wchar_t *full,wchar_t **leaf) {
  wchar_t *p=wide((char*)name); if(!p) return INVALID_HANDLE_VALUE;
  DWORD n=GetFullPathNameW(p,32768,full,NULL);
  DWORD err=GetLastError();
  free(p);
  if(!n) { fail("resolve output pair",err); return INVALID_HANDLE_VALUE; }
  if(n>=32768) { fail("resolve output pair",ERROR_FILENAME_EXCED_RANGE); return INVALID_HANDLE_VALUE; }
  wchar_t *slash=wcsrchr(full,L'\\');
  if(!slash || !slash[1]) { fail("invalid output pair name",ERROR_INVALID_NAME); return INVALID_HANDLE_VALUE; }
  *leaf=slash+1;
  if(wcschr(*leaf,L':')) { fail("output pair alternate streams are unsupported",ERROR_INVALID_NAME); return INVALID_HANDLE_VALUE; }
  /* Win32 normalizes final dots/spaces; reject aliases conservatively even for
   * extended/case-sensitive paths. Never write using these normalized strings. */
  size_t leaf_len=wcslen(*leaf);
  while(leaf_len && ((*leaf)[leaf_len-1]==L'.' || (*leaf)[leaf_len-1]==L' ')) (*leaf)[--leaf_len]=0;
  if(!leaf_len) { fail("invalid output pair name",ERROR_INVALID_NAME); return INVALID_HANDLE_VALUE; }
  wchar_t first=slash[1]; slash[1]=0;
  HANDLE parent=CreateFileW(full,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
  slash[1]=first;
  if(parent==INVALID_HANDLE_VALUE) fail("open output pair parent",GetLastError());
  return parent;
}
#else
static int pair_parent(moonbit_bytes_t name,const char **leaf) {
  const char *path=(char*)name,*slash=strrchr(path,'/');
  *leaf=slash?slash+1:path;
  if(!**leaf || !strcmp(*leaf,".") || !strcmp(*leaf,"..")) { fail("invalid output pair name",EINVAL); return -1; }
  size_t n=slash?(size_t)(slash-path):1;
  char *parent=malloc(n+2); if(!parent) { fail("output pair parent allocation",ENOMEM); return -1; }
  if(!slash) strcpy(parent,"."); else if(!n) strcpy(parent,"/"); else { memcpy(parent,path,n); parent[n]=0; }
  int fd=open(parent,O_RDONLY|O_DIRECTORY|O_CLOEXEC);
  int err=errno;
  free(parent);
  if(fd<0) fail("open output pair parent",err);
  return fd;
}
#endif
/* Zero-dependency Unicode 16.0 simple case-folding table (1-to-1 scalar mapping;
 * covers all Windows NTFS $UpCase pairs plus BMP/supplementary Unicode scripts). */
typedef struct {
  uint32_t start;
  uint32_t end;
  int32_t delta;
  uint8_t step;
} UnicodeFoldRun;

static const UnicodeFoldRun unicode_fold_runs[] = {
  {0x0041u,0x005Au,32,1}, {0x00B5u,0x00B5u,775,1}, {0x00C0u,0x00D6u,32,1}, {0x00D8u,0x00DEu,32,1},
  {0x0100u,0x012Eu,1,2}, {0x0132u,0x0136u,1,2}, {0x0139u,0x0147u,1,2}, {0x014Au,0x0176u,1,2},
  {0x0178u,0x0178u,-121,1}, {0x0179u,0x017Du,1,2}, {0x017Fu,0x017Fu,-268,1}, {0x0181u,0x0181u,210,1},
  {0x0182u,0x0184u,1,2}, {0x0186u,0x0186u,206,1}, {0x0187u,0x0187u,1,1}, {0x0189u,0x018Au,205,1},
  {0x018Bu,0x018Bu,1,1}, {0x018Eu,0x018Eu,79,1}, {0x018Fu,0x018Fu,202,1}, {0x0190u,0x0190u,203,1},
  {0x0191u,0x0191u,1,1}, {0x0193u,0x0193u,205,1}, {0x0194u,0x0194u,207,1}, {0x0196u,0x0196u,211,1},
  {0x0197u,0x0197u,209,1}, {0x0198u,0x0198u,1,1}, {0x019Cu,0x019Cu,211,1}, {0x019Du,0x019Du,213,1},
  {0x019Fu,0x019Fu,214,1}, {0x01A0u,0x01A4u,1,2}, {0x01A6u,0x01A6u,218,1}, {0x01A7u,0x01A7u,1,1},
  {0x01A9u,0x01A9u,218,1}, {0x01ACu,0x01ACu,1,1}, {0x01AEu,0x01AEu,218,1}, {0x01AFu,0x01AFu,1,1},
  {0x01B1u,0x01B2u,217,1}, {0x01B3u,0x01B5u,1,2}, {0x01B7u,0x01B7u,219,1}, {0x01B8u,0x01B8u,1,1},
  {0x01BCu,0x01BCu,1,1}, {0x01C4u,0x01C4u,2,1}, {0x01C5u,0x01C5u,1,1}, {0x01C7u,0x01C7u,2,1},
  {0x01C8u,0x01C8u,1,1}, {0x01CAu,0x01CAu,2,1}, {0x01CBu,0x01DBu,1,2}, {0x01DEu,0x01EEu,1,2},
  {0x01F1u,0x01F1u,2,1}, {0x01F2u,0x01F4u,1,2}, {0x01F6u,0x01F6u,-97,1}, {0x01F7u,0x01F7u,-56,1},
  {0x01F8u,0x021Eu,1,2}, {0x0220u,0x0220u,-130,1}, {0x0222u,0x0232u,1,2}, {0x023Au,0x023Au,10795,1},
  {0x023Bu,0x023Bu,1,1}, {0x023Du,0x023Du,-163,1}, {0x023Eu,0x023Eu,10792,1}, {0x0241u,0x0241u,1,1},
  {0x0243u,0x0243u,-195,1}, {0x0244u,0x0244u,69,1}, {0x0245u,0x0245u,71,1}, {0x0246u,0x024Eu,1,2},
  {0x0345u,0x0345u,116,1}, {0x0370u,0x0372u,1,2}, {0x0376u,0x0376u,1,1}, {0x037Fu,0x037Fu,116,1},
  {0x0386u,0x0386u,38,1}, {0x0388u,0x038Au,37,1}, {0x038Cu,0x038Cu,64,1}, {0x038Eu,0x038Fu,63,1},
  {0x0391u,0x03A1u,32,1}, {0x03A3u,0x03ABu,32,1}, {0x03C2u,0x03C2u,1,1}, {0x03CFu,0x03CFu,8,1},
  {0x03D0u,0x03D0u,-30,1}, {0x03D1u,0x03D1u,-25,1}, {0x03D5u,0x03D5u,-15,1}, {0x03D6u,0x03D6u,-22,1},
  {0x03D8u,0x03EEu,1,2}, {0x03F0u,0x03F0u,-54,1}, {0x03F1u,0x03F1u,-48,1}, {0x03F4u,0x03F4u,-60,1},
  {0x03F5u,0x03F5u,-64,1}, {0x03F7u,0x03F7u,1,1}, {0x03F9u,0x03F9u,-7,1}, {0x03FAu,0x03FAu,1,1},
  {0x03FDu,0x03FFu,-130,1}, {0x0400u,0x040Fu,80,1}, {0x0410u,0x042Fu,32,1}, {0x0460u,0x0480u,1,2},
  {0x048Au,0x04BEu,1,2}, {0x04C0u,0x04C0u,15,1}, {0x04C1u,0x04CDu,1,2}, {0x04D0u,0x052Eu,1,2},
  {0x0531u,0x0556u,48,1}, {0x10A0u,0x10C5u,7264,1}, {0x10C7u,0x10C7u,7264,1}, {0x10CDu,0x10CDu,7264,1},
  {0x13F8u,0x13FDu,-8,1}, {0x1C80u,0x1C80u,-6222,1}, {0x1C81u,0x1C81u,-6221,1}, {0x1C82u,0x1C82u,-6212,1},
  {0x1C83u,0x1C84u,-6210,1}, {0x1C85u,0x1C85u,-6211,1}, {0x1C86u,0x1C86u,-6204,1}, {0x1C87u,0x1C87u,-6180,1},
  {0x1C88u,0x1C88u,35267,1}, {0x1C89u,0x1C89u,1,1}, {0x1C90u,0x1CBAu,-3008,1}, {0x1CBDu,0x1CBFu,-3008,1},
  {0x1E00u,0x1E94u,1,2}, {0x1E9Bu,0x1E9Bu,-58,1}, {0x1E9Eu,0x1E9Eu,-7615,1}, {0x1EA0u,0x1EFEu,1,2},
  {0x1F08u,0x1F0Fu,-8,1}, {0x1F18u,0x1F1Du,-8,1}, {0x1F28u,0x1F2Fu,-8,1}, {0x1F38u,0x1F3Fu,-8,1},
  {0x1F48u,0x1F4Du,-8,1}, {0x1F59u,0x1F5Fu,-8,2}, {0x1F68u,0x1F6Fu,-8,1}, {0x1F88u,0x1F8Fu,-8,1},
  {0x1F98u,0x1F9Fu,-8,1}, {0x1FA8u,0x1FAFu,-8,1}, {0x1FB8u,0x1FB9u,-8,1}, {0x1FBAu,0x1FBBu,-74,1},
  {0x1FBCu,0x1FBCu,-9,1}, {0x1FBEu,0x1FBEu,-7173,1}, {0x1FC8u,0x1FCBu,-86,1}, {0x1FCCu,0x1FCCu,-9,1},
  {0x1FD8u,0x1FD9u,-8,1}, {0x1FDAu,0x1FDBu,-100,1}, {0x1FE8u,0x1FE9u,-8,1}, {0x1FEAu,0x1FEBu,-112,1},
  {0x1FECu,0x1FECu,-7,1}, {0x1FF8u,0x1FF9u,-128,1}, {0x1FFAu,0x1FFBu,-126,1}, {0x1FFCu,0x1FFCu,-9,1},
  {0x2126u,0x2126u,-7517,1}, {0x212Au,0x212Au,-8383,1}, {0x212Bu,0x212Bu,-8262,1}, {0x2132u,0x2132u,28,1},
  {0x2160u,0x216Fu,16,1}, {0x2183u,0x2183u,1,1}, {0x24B6u,0x24CFu,26,1}, {0x2C00u,0x2C2Fu,48,1},
  {0x2C60u,0x2C60u,1,1}, {0x2C62u,0x2C62u,-10743,1}, {0x2C63u,0x2C63u,-3814,1}, {0x2C64u,0x2C64u,-10727,1},
  {0x2C67u,0x2C6Bu,1,2}, {0x2C6Du,0x2C6Du,-10780,1}, {0x2C6Eu,0x2C6Eu,-10749,1}, {0x2C6Fu,0x2C6Fu,-10783,1},
  {0x2C70u,0x2C70u,-10782,1}, {0x2C72u,0x2C72u,1,1}, {0x2C75u,0x2C75u,1,1}, {0x2C7Eu,0x2C7Fu,-10815,1},
  {0x2C80u,0x2CE2u,1,2}, {0x2CEBu,0x2CEDu,1,2}, {0x2CF2u,0x2CF2u,1,1}, {0xA640u,0xA66Cu,1,2},
  {0xA680u,0xA69Au,1,2}, {0xA722u,0xA72Eu,1,2}, {0xA732u,0xA76Eu,1,2}, {0xA779u,0xA77Bu,1,2},
  {0xA77Du,0xA77Du,-35332,1}, {0xA77Eu,0xA786u,1,2}, {0xA78Bu,0xA78Bu,1,1}, {0xA78Du,0xA78Du,-42280,1},
  {0xA790u,0xA792u,1,2}, {0xA796u,0xA7A8u,1,2}, {0xA7AAu,0xA7AAu,-42308,1}, {0xA7ABu,0xA7ABu,-42319,1},
  {0xA7ACu,0xA7ACu,-42315,1}, {0xA7ADu,0xA7ADu,-42305,1}, {0xA7AEu,0xA7AEu,-42308,1}, {0xA7B0u,0xA7B0u,-42258,1},
  {0xA7B1u,0xA7B1u,-42282,1}, {0xA7B2u,0xA7B2u,-42261,1}, {0xA7B3u,0xA7B3u,928,1}, {0xA7B4u,0xA7C2u,1,2},
  {0xA7C4u,0xA7C4u,-48,1}, {0xA7C5u,0xA7C5u,-42307,1}, {0xA7C6u,0xA7C6u,-35384,1}, {0xA7C7u,0xA7C9u,1,2},
  {0xA7CBu,0xA7CBu,-42343,1}, {0xA7CCu,0xA7CCu,1,1}, {0xA7D0u,0xA7D0u,1,1}, {0xA7D6u,0xA7DAu,1,2},
  {0xA7DCu,0xA7DCu,-42561,1}, {0xA7F5u,0xA7F5u,1,1}, {0xAB70u,0xABBFu,-38864,1}, {0xFF21u,0xFF3Au,32,1},
  {0x10400u,0x10427u,40,1}, {0x104B0u,0x104D3u,40,1}, {0x10570u,0x1057Au,39,1}, {0x1057Cu,0x1058Au,39,1},
  {0x1058Cu,0x10592u,39,1}, {0x10594u,0x10595u,39,1}, {0x10C80u,0x10CB2u,64,1}, {0x10D50u,0x10D65u,32,1},
  {0x118A0u,0x118BFu,32,1}, {0x16E40u,0x16E5Fu,32,1}, {0x1E900u,0x1E921u,34,1}
};

static uint32_t unicode_fold_cp(uint32_t cp) {
  if(cp<0x80u) return (cp>='A' && cp<='Z')?(cp+32u):cp;
  size_t lo=0,hi=sizeof(unicode_fold_runs)/sizeof(unicode_fold_runs[0]);
  while(lo<hi) {
    size_t mid=lo+(hi-lo)/2u;
    if(cp<unicode_fold_runs[mid].start) hi=mid;
    else if(cp>unicode_fold_runs[mid].end) lo=mid+1u;
    else {
      const UnicodeFoldRun *r=&unicode_fold_runs[mid];
      if(((cp-r->start)%(uint32_t)r->step)==0u) return (uint32_t)((int32_t)cp+r->delta);
      return cp;
    }
  }
  return cp;
}

static size_t utf8_decode_one(const unsigned char *s,size_t n,uint32_t *out_cp) {
  if(!n) return 0;
  unsigned char c0=s[0];
  if(c0<0x80u) { *out_cp=(uint32_t)c0; return 1; }
  if(c0>=0xC2u && c0<=0xDFu) {
    if(n<2 || (s[1]&0xC0u)!=0x80u) return 0;
    *out_cp=((uint32_t)(c0&0x1Fu)<<6)|(uint32_t)(s[1]&0x3Fu);
    return 2;
  }
  if(c0>=0xE0u && c0<=0xEFu) {
    if(n<3 || (s[1]&0xC0u)!=0x80u || (s[2]&0xC0u)!=0x80u) return 0;
    if(c0==0xE0u && s[1]<0xA0u) return 0;
    if(c0==0xEDu && s[1]>0x9Fu) return 0;
    *out_cp=((uint32_t)(c0&0x0Fu)<<12)|((uint32_t)(s[1]&0x3Fu)<<6)|(uint32_t)(s[2]&0x3Fu);
    return 3;
  }
  if(c0>=0xF0u && c0<=0xF4u) {
    if(n<4 || (s[1]&0xC0u)!=0x80u || (s[2]&0xC0u)!=0x80u || (s[3]&0xC0u)!=0x80u) return 0;
    if(c0==0xF0u && s[1]<0x90u) return 0;
    if(c0==0xF4u && s[1]>0x8Fu) return 0;
    *out_cp=((uint32_t)(c0&0x07u)<<18)|((uint32_t)(s[1]&0x3Fu)<<12)|
            ((uint32_t)(s[2]&0x3Fu)<<6)|(uint32_t)(s[3]&0x3Fu);
    return 4;
  }
  return 0;
}

static size_t utf8_encode_one(uint32_t cp,unsigned char out[4]) {
  if(cp<0x80u) { out[0]=(unsigned char)cp; return 1; }
  if(cp<0x800u) {
    out[0]=(unsigned char)(0xC0u|(cp>>6));
    out[1]=(unsigned char)(0x80u|(cp&0x3Fu));
    return 2;
  }
  if(cp<0x10000u) {
    out[0]=(unsigned char)(0xE0u|(cp>>12));
    out[1]=(unsigned char)(0x80u|((cp>>6)&0x3Fu));
    out[2]=(unsigned char)(0x80u|(cp&0x3Fu));
    return 3;
  }
  out[0]=(unsigned char)(0xF0u|(cp>>18));
  out[1]=(unsigned char)(0x80u|((cp>>12)&0x3Fu));
  out[2]=(unsigned char)(0x80u|((cp>>6)&0x3Fu));
  out[3]=(unsigned char)(0x80u|(cp&0x3Fu));
  return 4;
}

static moonbit_bytes_t unicode_fold_utf8_buf(const unsigned char *src,size_t len) {
  if(!len) return bytes(NULL,0);
  size_t cap=len+16u;
  unsigned char *out=malloc(cap);
  if(!out) { fail("case fold allocation",ENOMEM); return bytes(NULL,0); }
  size_t pos=0,used=0;
  while(pos<len) {
    uint32_t cp=0;
    size_t step=utf8_decode_one(src+pos,len-pos,&cp);
    if(!step) {
      free(out);
      fail("invalid UTF-8 in case fold",EINVAL);
      return bytes(NULL,0);
    }
    uint32_t folded=unicode_fold_cp(cp);
    unsigned char enc[4];
    size_t elen=utf8_encode_one(folded,enc);
    if(used+elen>cap) {
      size_t next=cap*2u;
      if(next<used+elen) next=used+elen+16u;
      unsigned char *grown=realloc(out,next);
      if(!grown) { free(out); fail("case fold allocation",ENOMEM); return bytes(NULL,0); }
      out=grown; cap=next;
    }
    memcpy(out+used,enc,elen);
    used+=elen;
    pos+=step;
  }
  moonbit_bytes_t result=bytes(out,used);
  free(out);
  return result;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mbsd_case_fold_utf8(moonbit_bytes_t utf8_in) {
  problem[0]=0;
  int32_t in_len=Moonbit_array_length(utf8_in);
  if(in_len<=0) return bytes(NULL,0);
#ifdef _WIN32
  int wlen=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,(const char *)utf8_in,in_len,NULL,0);
  if(wlen<=0) { fail("UTF-8 case fold conversion",GetLastError()); return bytes(NULL,0); }
  wchar_t *wbuf=malloc((size_t)wlen*sizeof(wchar_t));
  if(!wbuf) { fail("case fold allocation",ERROR_NOT_ENOUGH_MEMORY); return bytes(NULL,0); }
  if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,(const char *)utf8_in,in_len,wbuf,wlen)) {
    DWORD e=GetLastError(); free(wbuf); fail("UTF-8 case fold conversion",e); return bytes(NULL,0);
  }
  int ulen=LCMapStringEx(LOCALE_NAME_INVARIANT,LCMAP_UPPERCASE,wbuf,wlen,NULL,0,NULL,NULL,0);
  if(ulen<=0) { DWORD e=GetLastError(); free(wbuf); fail("Windows invariant case fold",e); return bytes(NULL,0); }
  wchar_t *ubuf=malloc((size_t)ulen*sizeof(wchar_t));
  if(!ubuf) { free(wbuf); fail("case fold allocation",ERROR_NOT_ENOUGH_MEMORY); return bytes(NULL,0); }
  if(!LCMapStringEx(LOCALE_NAME_INVARIANT,LCMAP_UPPERCASE,wbuf,wlen,ubuf,ulen,NULL,NULL,0)) {
    DWORD e=GetLastError(); free(wbuf); free(ubuf); fail("Windows invariant case fold",e); return bytes(NULL,0);
  }
  free(wbuf);
  int mlen=WideCharToMultiByte(CP_UTF8,0x00000080 /* WC_ERR_INVALID_CHARS */,ubuf,ulen,NULL,0,NULL,NULL);
  if(mlen<=0) { DWORD e=GetLastError(); free(ubuf); fail("UTF-8 case fold conversion",e); return bytes(NULL,0); }
  unsigned char *mid=malloc((size_t)mlen);
  if(!mid) { free(ubuf); fail("case fold allocation",ERROR_NOT_ENOUGH_MEMORY); return bytes(NULL,0); }
  if(!WideCharToMultiByte(CP_UTF8,0x00000080 /* WC_ERR_INVALID_CHARS */,ubuf,ulen,(char *)mid,mlen,NULL,NULL)) {
    DWORD e=GetLastError(); free(ubuf); free(mid); fail("UTF-8 case fold conversion",e); return bytes(NULL,0);
  }
  free(ubuf);
  moonbit_bytes_t result=unicode_fold_utf8_buf(mid,(size_t)mlen);
  free(mid);
  return result;
#else
  return unicode_fold_utf8_buf((const unsigned char *)utf8_in,(size_t)in_len);
#endif
}

#ifndef _WIN32
static int utf8_case_equal(const char *a,const char *b) {
  const unsigned char *pa=(const unsigned char *)a;
  const unsigned char *pb=(const unsigned char *)b;
  size_t la=strlen(a),lb=strlen(b),ia=0,ib=0;
  while(ia<la && ib<lb) {
    uint32_t ca=0,cb=0;
    size_t sa=utf8_decode_one(pa+ia,la-ia,&ca);
    size_t sb=utf8_decode_one(pb+ib,lb-ib,&cb);
    if(!sa || !sb) {
      if(pa[ia]!=pb[ib]) return 0;
      ia++; ib++;
      continue;
    }
    if(unicode_fold_cp(ca)!=unicode_fold_cp(cb)) return 0;
    ia+=sa; ib+=sb;
  }
  return ia==la && ib==lb;
}
#ifdef __linux__
static int is_case_insensitive_dir(int fd) {
  struct statfs fs;
  if(fstatfs(fd,&fs)==0) {
    unsigned long t=(unsigned long)fs.f_type;
    if(t==0x4d44UL /* MSDOS/FAT */ || t==0x2011BAB0UL /* EXFAT */ ||
       t==0x5346544eUL /* NTFS */ || t==0x7366746eUL /* NTFS3 */ ||
       t==0x65735546UL /* FUSE/ntfs-3g */ ||
       t==0xFF534D42UL /* CIFS */ || t==0xFE534D42UL /* SMB2 */ ||
       t==0x517BUL /* SMB */ || t==0x01021997UL /* V9FS/WSL DrvFs */)
      return 1;
  }
  int flags=0;
  if(ioctl(fd,FS_IOC_GETFLAGS,&flags)==0 && (flags & FS_CASEFOLD_FL)) return 1;
  return 0;
}
#elif defined(__APPLE__)
static int is_case_insensitive_dir(int fd) {
  long cs=fpathconf(fd,_PC_CASE_SENSITIVE);
  return cs<=0;
}
#endif
#endif
MOONBIT_FFI_EXPORT int32_t mbsd_pair_check(moonbit_bytes_t a,moonbit_bytes_t b) {
  problem[0]=0;
#ifdef _WIN32
  wchar_t *full_a=malloc(32768*sizeof(wchar_t));
  wchar_t *full_b=malloc(32768*sizeof(wchar_t));
  if(!full_a || !full_b) { free(full_a); free(full_b); fail("output pair allocation",ERROR_NOT_ENOUGH_MEMORY); return 0; }
  wchar_t *leaf_a=NULL,*leaf_b=NULL;
  HANDLE pa=pair_parent(a,full_a,&leaf_a),pb=pair_parent(b,full_b,&leaf_b);
  if(pa!=INVALID_HANDLE_VALUE && pb!=INVALID_HANDLE_VALUE) {
    BY_HANDLE_FILE_INFORMATION ia,ib;
    if(!GetFileInformationByHandle(pa,&ia) || !GetFileInformationByHandle(pb,&ib)) fail("output pair parent identity",GetLastError());
    else if(!(ia.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY) || !(ib.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)) fail("output pair parent is not a directory",ERROR_DIRECTORY);
    else if(ia.dwVolumeSerialNumber==ib.dwVolumeSerialNumber && ia.nFileIndexHigh==ib.nFileIndexHigh && ia.nFileIndexLow==ib.nFileIndexLow) {
      /* Conservatively reject case aliases even in case-sensitive Windows dirs. */
      int equal=CompareStringOrdinal(leaf_a,-1,leaf_b,-1,TRUE);
      if(!equal) fail("compare output pair names",GetLastError());
      else if(equal==CSTR_EQUAL || win_maybe_short_name_alias(leaf_a,leaf_b)) fail("paths resolve to the same target",ERROR_ALREADY_EXISTS);
    }
  }
  if(pa!=INVALID_HANDLE_VALUE && !CloseHandle(pa)) fail("close output pair parent",GetLastError());
  if(pb!=INVALID_HANDLE_VALUE && !CloseHandle(pb)) fail("close output pair parent",GetLastError());
  free(full_a); free(full_b);
#else
  const char *leaf_a=NULL,*leaf_b=NULL;
  int pa=pair_parent(a,&leaf_a),pb=pair_parent(b,&leaf_b);
  if(pa>=0 && pb>=0) {
    struct stat ia,ib;
    if(fstat(pa,&ia)<0 || fstat(pb,&ib)<0) fail("output pair parent identity",errno);
    else if(ia.st_dev==ib.st_dev && ia.st_ino==ib.st_ino) {
      int same=!strcmp(leaf_a,leaf_b) || (is_case_insensitive_dir(pa) && utf8_case_equal(leaf_a,leaf_b));
      if(same) fail("paths resolve to the same target",EEXIST);
    }
  }
  if(pa>=0 && close(pa)<0) fail("close output pair parent",errno);
  if(pb>=0 && close(pb)<0) fail("close output pair parent",errno);
#endif
  return !problem[0];
}

#ifndef _WIN32
#ifdef __linux__
/* Set only by the private compatibility contract entrypoint. No product knobs. */
IO_TEST(static int compat_force,compat_mutate,compat_selected,compat_retained;)
IO_TEST(static char compat_last[80];)
#endif
static int same_inode(const struct stat *a,const struct stat *b) {
  return a->st_dev==b->st_dev && a->st_ino==b->st_ino;
}
static int private_entry(int dir,const char *name,int held,const struct stat *created) {
  struct stat named,current;
  return fstat(held,&current)==0 && S_ISDIR(current.st_mode) && current.st_uid==geteuid() &&
    (current.st_mode&05777)==0700 && same_inode(&current,created) &&
    fstatat(dir,name,&named,AT_SYMLINK_NOFOLLOW)==0 && same_inode(&named,created);
}
static int payload_entry(int dir,const struct stat *created) {
  struct stat named;
  return fstatat(dir,"payload",&named,AT_SYMLINK_NOFOLLOW)==0 && S_ISREG(named.st_mode) &&
    named.st_uid==geteuid() && (named.st_mode&07777)==0600 && same_inode(&named,created);
}
static void retained(const char *name) {
#ifdef __linux__
  IO_TEST(compat_retained=1;)
#endif
  size_t used=strlen(problem);
  snprintf(problem+used,sizeof(problem)-used,"; private temporary retained or renamed: %s (do not blindly delete)",name);
}
static int random_name(char name[80]) {
  unsigned char token[16];
  if(!fill_csprng(token,sizeof(token))) return 0;
  strcpy(name,".moonbsdiff-compat-");size_t prefix=strlen(name);
  static const char hex[]="0123456789abcdef";
  for(size_t i=0;i<sizeof(token);i++) { name[prefix+i*2]=hex[token[i]>>4];name[prefix+i*2+1]=hex[token[i]&15]; }
  name[prefix+sizeof(token)*2]=0;return 1;
}
static void posix_write_payload(int writer,moonbit_bytes_t data) {
  size_t at=0,n=data?Moonbit_array_length(data):0;
  if(!data && !problem[0]) stream_populate(writer);
  while(!problem[0] && at<n) {
    size_t amount=n-at>32768?32768:n-at;
    IO_TEST(if(fault==9 && amount>2) amount=2;)
    IO_TEST(if(fault==4 && at) { fail("injected write",EIO);break; })
    IO_TEST(if(fault==4) amount=1;)
    ssize_t done=IO_TEST(fault==10?0:)write(writer,data+at,amount);
    if(done<0 && errno==EINTR) continue;
    if(done<=0) { fail("write private payload",done<0?errno:EIO);break; }
    at+=(size_t)done;
  }
}
static void posix_cleanup_private(int dir,const char *name,int private_fd,const struct stat *ds,
                                  int made,int known_dir,int payload_made,int payload,
                                  const struct stat *ps,int force_dirty) {
  int clean=!force_dirty;
  if(private_fd>=0) {
    if(!private_entry(dir,name,private_fd,ds)) clean=0;
    if(clean && payload_made) {
      if(!payload || !payload_entry(private_fd,ps)) clean=0;
      else if(unlinkat(private_fd,"payload",0)<0) { fail("cleanup owned private payload",errno);clean=0; }
    }
  } else if(payload_made) clean=0;
  if(clean && made && known_dir) {
    struct stat named;
    if(fstatat(dir,name,&named,AT_SYMLINK_NOFOLLOW)<0 || !same_inode(&named,ds)) clean=0;
    else if(unlinkat(dir,name,AT_REMOVEDIR)<0) { fail("cleanup owned private directory",errno);clean=0; }
  } else if(!known_dir) clean=0;
  if(!clean) { fail("private cleanup ownership uncertain",ESTALE);retained(name); }
}
#ifdef __linux__
static int compat_deliver(int dir,const char *leaf,moonbit_bytes_t data) {
  IO_TEST(compat_selected++;)
  struct stat parent,ds,ps;struct statfs fs;
  if(fstat(dir,&parent)<0 || fstatfs(dir,&fs)<0) { fail("compatibility parent metadata",errno);return 0; }
  /* Restrict permission assumptions to the locally validated ext filesystem.
   * Non-sticky writable parents and untrusted owners cannot protect mkdir/open. */
  if(fs.f_type!=EXT4_SUPER_MAGIC || !S_ISDIR(parent.st_mode) || parent.st_nlink==0 ||
     (parent.st_uid!=geteuid() && parent.st_uid!=0) ||
     ((parent.st_mode&0022) && !(parent.st_mode&S_ISVTX))) {
    fail("compatibility requires local ext permissions and protected output parent",EPERM);return 0;
  }
  int made=0,known_dir=0,payload_made=0,payload=0,private_fd=-1,writer=-1,keeper=-1;
  char name[80]={0};
  for(unsigned attempt=0;attempt<128;attempt++) {
    IO_TEST(if(compat_mutate==1 && !attempt) strcpy(name,".moonbsdiff-compat-collision"); else)
    if(!random_name(name)) return 0;
    if(mkdirat(dir,name,0700)==0) { made=1;break; }
    if(errno!=EEXIST) { fail("exclusive private directory creation",errno);return 0; }
  }
  if(!made) { fail("private directory name collisions exhausted",EEXIST);return 0; }
  IO_TEST(strcpy(compat_last,name);)
  if(fstatat(dir,name,&ds,AT_SYMLINK_NOFOLLOW)<0) fail("created private directory identity",errno);
  else {
    known_dir=1;
    if(!S_ISDIR(ds.st_mode) || ds.st_uid!=geteuid() || (ds.st_mode&05777)!=0700) fail("private directory permissions",EPERM);
  }
  if(!problem[0]) {
    private_fd=openat(dir,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(private_fd<0) fail("open private directory",errno);
    else if(!private_entry(dir,name,private_fd,&ds)) fail("private directory identity changed",ESTALE);
  }
  if(!problem[0]) {
    writer=openat(private_fd,"payload",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(writer<0) fail("exclusive private payload creation",errno);
    else {
      payload_made=1;
      if(fstat(writer,&ps)<0) fail("private payload identity",errno);
      else {
        payload=1;
        if(!S_ISREG(ps.st_mode) || ps.st_uid!=geteuid() || (ps.st_mode&07777)!=0600 || ps.st_nlink!=1) fail("private payload permissions",EPERM);
      }
    }
  }
  if(!problem[0]) {
    keeper=openat(private_fd,"payload",O_PATH|O_NOFOLLOW|O_CLOEXEC);
    struct stat held;
    if(keeper<0 || fstat(keeper,&held)<0) fail("retain private payload identity",errno);
    else if(!same_inode(&held,&ps)) fail("private payload changed on open",ESTALE);
  }
  posix_write_payload(writer,data);
  if(writer>=0) { if(close(writer)<0) fail("close written private payload",errno);writer=-1; }
  IO_TEST(if(fault==5) fail("injected close written private payload",EIO);)
#ifdef MBSD_IO_TEST
  if(!problem[0] && compat_mutate==2) {
    int other=openat(dir,leaf,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);
    if(other<0 || write(other,"other",5)!=5) fail("test competing target",EIO);
    if(other>=0) close(other);
  }
  if(!problem[0] && compat_mutate==3) {
    if(unlinkat(private_fd,"payload",0)<0 || symlinkat("../input",private_fd,"payload")<0) fail("test payload replacement",errno);
  }
  if(!problem[0] && compat_mutate==4) {
    if(renameat(dir,name,dir,"retained-original")<0 || mkdirat(dir,name,0700)<0) fail("test directory replacement",errno);
  }
#endif

  if(!problem[0] && (!private_entry(dir,name,private_fd,&ds) || !payload_entry(private_fd,&ps))) fail("private temporary identity changed before delivery",ESTALE);
  IO_TEST(if(!problem[0] && fault==6) fail("injected compatibility delivery",EACCES);)
  if(!data && !problem[0]) stream_prepare_commit();
  int committed=0;
  if(!problem[0]) {
    if(linkat(private_fd,"payload",dir,leaf,0)<0) fail("compatibility deliver without replacement",errno);
    else { committed=1; mark_delivery(data); }
  }
  /* These deletes rely on the protected parent and uid-private directory, NOT
   * on an atomic check/unlink illusion. Malicious same-uid/root control is out
   * of scope. Unexpected identity => retain, never follow/delete replacement. */
  int force_dirty=0;
  IO_TEST(if(compat_mutate==5 && committed) { fail("injected compatibility cleanup",EIO);force_dirty=1; })
  posix_cleanup_private(dir,name,private_fd,&ds,made,known_dir,payload_made,payload,&ps,force_dirty);
  if(keeper>=0 && close(keeper)<0) fail("close private identity reference",errno);
  if(private_fd>=0 && close(private_fd)<0) fail("close private directory",errno);
  if(committed && problem[0]) annotate_delivered_problem();
  return !problem[0];
}
static int anonymous_unavailable(int error) {
  return error==EOPNOTSUPP || error==EINVAL || error==EISDIR || error==ENOSYS || error==ENOENT;
}
#elif defined(__APPLE__)
static int apple_deliver(int dir,const char *leaf,moonbit_bytes_t data,const char *path) {
  (void)path;
  struct stat parent,ds,ps;
  if(fstat(dir,&parent)<0) { fail("output parent metadata",errno);return 0; }
  if(!S_ISDIR(parent.st_mode) || parent.st_nlink==0 ||
     (parent.st_uid!=geteuid() && parent.st_uid!=0) ||
     ((parent.st_mode&0022) && !(parent.st_mode&S_ISVTX))) {
    fail("output requires protected parent permissions",EPERM);return 0;
  }
  int made=0,known_dir=0,payload_made=0,payload=0,private_fd=-1,writer=-1,keeper=-1;
  char name[80]={0};
  for(unsigned attempt=0;attempt<128;attempt++) {
    IO_TEST(if(fault==1 && !attempt) strcpy(name,".moonbsdiff-collision.tmp"); else)
    if(!random_name(name)) return 0;
    if(mkdirat(dir,name,0700)==0) { made=1;break; }
    if(errno!=EEXIST) { fail("exclusive private directory creation",errno);return 0; }
  }
  if(!made) { fail("private directory name collisions exhausted",EEXIST);return 0; }
  if(fstatat(dir,name,&ds,AT_SYMLINK_NOFOLLOW)<0) fail("created private directory identity",errno);
  else {
    known_dir=1;
    if(!S_ISDIR(ds.st_mode) || ds.st_uid!=geteuid() || (ds.st_mode&05777)!=0700) fail("private directory permissions",EPERM);
  }
  if(!problem[0]) {
    private_fd=openat(dir,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(private_fd<0) fail("open private directory",errno);
    else if(!private_entry(dir,name,private_fd,&ds)) fail("private directory identity changed",ESTALE);
  }
  if(!problem[0]) {
    writer=openat(private_fd,"payload",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(writer<0) fail("exclusive private payload creation",errno);
    else {
      payload_made=1;
      if(fstat(writer,&ps)<0) fail("private payload identity",errno);
      else {
        payload=1;
        if(!S_ISREG(ps.st_mode) || ps.st_uid!=geteuid() || (ps.st_mode&07777)!=0600 || ps.st_nlink!=1) fail("private payload permissions",EPERM);
      }
    }
  }
  if(!problem[0]) {
    keeper=openat(private_fd,"payload",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    struct stat held;
    if(keeper<0 || fstat(keeper,&held)<0) fail("retain private payload identity",errno);
    else if(!same_inode(&held,&ps)) fail("private payload changed on open",ESTALE);
  }
  posix_write_payload(writer,data);
  if(writer>=0) { if(close(writer)<0) fail("close written private payload",errno);writer=-1; }
  IO_TEST(if(fault==5) fail("injected close written private payload",EIO);)
  IO_TEST(if(!problem[0] && fault==2 && !test_put(path,"other",5,0)) fail("test target creation",EIO);)
  if(!problem[0] && (!private_entry(dir,name,private_fd,&ds) || !payload_entry(private_fd,&ps))) fail("private temporary identity changed before delivery",ESTALE);
  IO_TEST(if(!problem[0] && fault==6) fail("injected delivery",EACCES);)
  if(!data && !problem[0]) stream_prepare_commit();
  int committed=0;
  if(!problem[0]) {
    if(linkat(private_fd,"payload",dir,leaf,0)<0) fail("deliver without replacement",errno);
    else { committed=1; mark_delivery(data); }
  }
  posix_cleanup_private(dir,name,private_fd,&ds,made,known_dir,payload_made,payload,&ps,0);
  if(keeper>=0 && close(keeper)<0) fail("close private identity reference",errno);
  if(private_fd>=0 && close(private_fd)<0) fail("close private directory",errno);
  if(committed && problem[0]) annotate_delivered_problem();
  return !problem[0];
}
#endif
#endif

static int deliver_secret_mode=0;
#ifdef _WIN32
static PSECURITY_DESCRIPTOR win_owner_sd(void) {
  typedef BOOL (WINAPI *fn_open_token)(HANDLE,DWORD,PHANDLE);
  typedef BOOL (WINAPI *fn_token_info)(HANDLE,TOKEN_INFORMATION_CLASS,LPVOID,DWORD,PDWORD);
  typedef BOOL (WINAPI *fn_sid_str)(PSID,LPWSTR*);
  typedef BOOL (WINAPI *fn_str_sd)(LPCWSTR,DWORD,PSECURITY_DESCRIPTOR*,PULONG);
  HMODULE adv=LoadLibraryExW(L"advapi32.dll",NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
  if(!adv) { fail("load security provider",GetLastError()); return NULL; }
  fn_open_token open_tok=(fn_open_token)GetProcAddress(adv,"OpenProcessToken");
  fn_token_info tok_info=(fn_token_info)GetProcAddress(adv,"GetTokenInformation");
  fn_sid_str sid_str=(fn_sid_str)GetProcAddress(adv,"ConvertSidToStringSidW");
  fn_str_sd str_sd=(fn_str_sd)GetProcAddress(adv,"ConvertStringSecurityDescriptorToSecurityDescriptorW");
  if(!open_tok || !tok_info || !sid_str || !str_sd) {
    DWORD e=GetLastError(); FreeLibrary(adv);
    fail("resolve security provider",e?e:ERROR_PROC_NOT_FOUND);
    return NULL;
  }
  HANDLE tok=NULL; TOKEN_USER *tu=NULL; LPWSTR sid=NULL; wchar_t *sddl=NULL; PSECURITY_DESCRIPTOR sd=NULL;
  if(!open_tok(GetCurrentProcess(),TOKEN_QUERY,&tok)) {
    fail("open process token",GetLastError()); goto done;
  }
  DWORD needed=0;
  if(!tok_info(tok,TokenUser,NULL,0,&needed) && GetLastError()!=ERROR_INSUFFICIENT_BUFFER) {
    fail("query token user size",GetLastError()); goto done;
  }
  if(!needed) { fail("query token user size",ERROR_INVALID_DATA); goto done; }
  tu=malloc(needed);
  if(!tu) { fail("token user allocation",ERROR_NOT_ENOUGH_MEMORY); goto done; }
  if(!tok_info(tok,TokenUser,tu,needed,&needed)) {
    fail("query token user",GetLastError()); goto done;
  }
  if(!sid_str(tu->User.Sid,&sid) || !sid) {
    fail("format owner SID",GetLastError()); goto done;
  }
  size_t cap=wcslen(sid)+32;
  sddl=malloc(cap*sizeof(wchar_t));
  if(!sddl) { fail("security descriptor allocation",ERROR_NOT_ENOUGH_MEMORY); goto done; }
  int written=swprintf(sddl,cap,L"D:P(A;;FA;;;%ls)",sid);
  if(written<=0 || (size_t)written>=cap) {
    fail("format owner security descriptor",ERROR_INVALID_DATA); goto done;
  }
  if(!str_sd(sddl,1,&sd,NULL) || !sd) {
    fail("build owner security descriptor",GetLastError()); sd=NULL; goto done;
  }
done:
  if(sddl) free(sddl);
  if(sid) LocalFree(sid);
  if(tu) free(tu);
  if(tok) CloseHandle(tok);
  FreeLibrary(adv);
  return sd;
}
#endif

/* Never removes final caller paths. Primary cleanup uses held identities;
 * compatibility cleanup uses only the protected private namespace above. */
MOONBIT_FFI_EXPORT int32_t mbsd_deliver(moonbit_bytes_t name,moonbit_bytes_t data) {
  int secret=deliver_secret_mode; deliver_secret_mode=0;
  delivery_committed=0; problem[0]=0; size_t n=data?Moonbit_array_length(data):0,at=0;
#ifdef _WIN32
  wchar_t *relative=wide((char*)name); if(!relative) return 0;
  if(!win_validate_output_path(relative)) { free(relative); return 0; }
  wchar_t *full=malloc(32768*sizeof(wchar_t));
  wchar_t *temp=malloc(32768*sizeof(wchar_t));
  if(!full || !temp) { free(relative); free(full); free(temp); fail("output path allocation",ERROR_NOT_ENOUGH_MEMORY); return 0; }
  DWORD length=GetFullPathNameW(relative,32768,full,NULL);
  DWORD resolve_err=GetLastError();
  free(relative);
  if(!length) { free(full); free(temp); fail("resolve output",resolve_err); return 0; }
  if(length>=32768) { free(full); free(temp); fail("resolve output",ERROR_FILENAME_EXCED_RANGE); return 0; }
  wchar_t *slash=wcsrchr(full,L'\\');
  if(!slash || !slash[1] || slash-full>32000) { free(full); free(temp); fail("output parent",ERROR_INVALID_NAME); return 0; }
  size_t parent=(size_t)(slash-full)+1;
  PSECURITY_DESCRIPTOR sd=NULL;
  SECURITY_ATTRIBUTES sa={sizeof(sa),NULL,FALSE};
  if(secret) {
    sd=win_owner_sd();
    if(!sd) { free(full); free(temp); return 0; }
    sa.lpSecurityDescriptor=sd;
  }
  HANDLE writer=INVALID_HANDLE_VALUE,keeper=INVALID_HANDLE_VALUE;
  for(unsigned attempt=0;attempt<128;attempt++) {
    memcpy(temp,full,parent*sizeof(wchar_t));
    IO_TEST(if(fault==1 && attempt==0) wcscpy(temp+parent,L".moonbsdiff-collision.tmp"); else)
    {
      wchar_t hex[33];
      if(!win_random_hex(hex)) { if(sd) LocalFree(sd); free(full); free(temp); return 0; }
      swprintf(temp+parent,32768-parent,L".moonbsdiff-%ls.tmp",hex);
    }
    writer=CreateFileW(temp,GENERIC_WRITE|DELETE|FILE_READ_ATTRIBUTES,0,secret?&sa:NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if(writer!=INVALID_HANDLE_VALUE) break;
    DWORD e=GetLastError(); if(e!=ERROR_FILE_EXISTS && e!=ERROR_ALREADY_EXISTS) { if(sd) LocalFree(sd); free(full); free(temp); fail("exclusive temporary creation",e); return 0; }
  }
  if(sd) { LocalFree(sd); sd=NULL; }
  if(writer==INVALID_HANDLE_VALUE) { free(full); free(temp); fail("temporary name collisions exhausted",ERROR_FILE_EXISTS); return 0; }
  if(!DuplicateHandle(GetCurrentProcess(),writer,GetCurrentProcess(),&keeper,DELETE|FILE_READ_ATTRIBUTES, FALSE,0)) fail("retain temporary identity",GetLastError());
  if(!data && !problem[0]) stream_populate(writer);
  while(!problem[0] && at<n) {
    DWORD amount=(DWORD)(n-at>32768?32768:n-at),done=0;
    IO_TEST(if(fault==9 && amount>2) amount=2;)
    IO_TEST(if(fault==4 && at) { fail("injected write",ERROR_WRITE_FAULT); break; })
    IO_TEST(if(fault==4) amount=1;)
    if(!windows_write(writer,data+at,amount,&done,"write temporary")) break;
    at+=done;
  }
  if(keeper==INVALID_HANDLE_VALUE) { FILE_DISPOSITION_INFO del={TRUE}; if(!SetFileInformationByHandle(writer,FileDispositionInfo,&del,sizeof(del))) fail("cleanup temporary",GetLastError()); }
  if(!CloseHandle(writer)) fail("close written temporary",GetLastError());
  IO_TEST(if(fault==5) fail("injected close written temporary",ERROR_WRITE_FAULT);)
  IO_TEST(if(!problem[0] && fault==2 && !test_put((char*)name,"other",5,0)) fail("test target creation",EIO);)
  IO_TEST(if(!problem[0] && fault==6) fail("injected delivery",ERROR_ACCESS_DENIED);)
  if(!data && !problem[0]) stream_prepare_commit();
  if(!problem[0]) {
    size_t size=sizeof(FILE_RENAME_INFO)+((size_t)length+1)*sizeof(wchar_t);
    FILE_RENAME_INFO *rename=calloc(1,size);
    if(!rename) fail("rename allocation",ERROR_NOT_ENOUGH_MEMORY);
    else {
      rename->ReplaceIfExists=FALSE; rename->RootDirectory=NULL; rename->FileNameLength=length*sizeof(wchar_t);
      memcpy(rename->FileName,full,length*sizeof(wchar_t));
      if(!SetFileInformationByHandle(keeper,FileRenameInfo,rename,(DWORD)size)) fail("deliver without replacement",GetLastError());
      else mark_delivery(data);
      free(rename);
    }
  }
  if(keeper!=INVALID_HANDLE_VALUE) {
    if(problem[0]) { FILE_DISPOSITION_INFO del={TRUE}; if(!SetFileInformationByHandle(keeper,FileDispositionInfo,&del,sizeof(del))) fail("cleanup temporary",GetLastError()); }
    if(!CloseHandle(keeper)) fail("close temporary identity",GetLastError());
  }
  free(full); free(temp);
  annotate_delivered_problem();
#else
  const char *path=(char*)name,*slash=strrchr(path,'/'),*leaf=slash?slash+1:path;
  size_t parent_len=slash?(size_t)(slash-path):1;
  char *parent=malloc(parent_len+2);
  if(!parent) { fail("parent allocation",ENOMEM); return 0; }
  if(slash) { if(!parent_len) strcpy(parent,"/"); else { memcpy(parent,path,parent_len); parent[parent_len]=0; } } else strcpy(parent,".");
  if(!*leaf || !strcmp(leaf,".") || !strcmp(leaf,"..")) { free(parent); fail("invalid output name",EINVAL); return 0; }
  int dir=open(parent,O_RDONLY|O_DIRECTORY|O_CLOEXEC);
  int open_err=errno;
  free(parent);
  if(dir<0) { fail("open output directory",open_err); return 0; }
#ifdef __APPLE__
  (void)secret; (void)n; (void)at;
  apple_deliver(dir,leaf,data,path);
  if(close(dir)<0) fail("close output directory",errno);
  annotate_delivered_problem();
#else
  /* O_TMPFILE creates a fresh unnamed inode. O_EXCL must not be used here:
   * Linux defines O_TMPFILE|O_EXCL to forbid its later linking. */
  int writer,keeper=-1;
  IO_TEST(if(compat_force==1 || compat_force==2) { writer=-1;errno=compat_force==1?EOPNOTSUPP:EACCES; } else)
  writer=openat(dir,".",O_TMPFILE|O_RDWR|O_CLOEXEC,0600);
  if(writer<0) {
    int error=errno;
    if(anonymous_unavailable(error)) compat_deliver(dir,leaf,data);
    else fail("anonymous temporary creation",error);
    if(close(dir)<0) fail("close output directory",errno);
    annotate_delivered_problem();
    return !problem[0];
  }
  if(secret) {
    struct stat st;
    if(fstat(writer,&st)<0) fail("inspect secret temporary permissions",errno);
    else if(!S_ISREG(st.st_mode) || st.st_uid!=geteuid() || (st.st_mode&07777)!=0600) fail("secret output requires private 0600 permissions",EPERM);
    if(problem[0]) {
      if(close(writer)<0) fail("close rejected secret temporary",errno);
      if(close(dir)<0) fail("close output directory",errno);
      return 0;
    }
  }
  char reference[80]; snprintf(reference,sizeof(reference),"/proc/self/fd/%d",writer);
  IO_TEST(if(compat_force==3 || compat_force==4) { keeper=-1;errno=ENOENT; } else)
  keeper=open(reference,O_PATH|O_CLOEXEC);
  if(keeper<0) {
    int error=errno;
    int closed=close(writer)==0,close_error=closed?0:errno;
    IO_TEST(if(compat_force==4) { closed=0;close_error=EIO; })
    if(!closed) fail("close anonymous temporary before compatibility",close_error);
    else if(error==ENOENT || error==ENOTDIR) compat_deliver(dir,leaf,data);
    else fail("retain temporary identity",error);
    if(close(dir)<0) fail("close output directory",errno);
    annotate_delivered_problem();
    return !problem[0];
  }
  if(!data && !problem[0]) stream_populate(writer);
  while(!problem[0] && at<n) {
    size_t amount=n-at>32768?32768:n-at;
    IO_TEST(if(fault==9 && amount>2) amount=2;)
    IO_TEST(if(fault==4 && at) { fail("injected write",EIO); break; })
    IO_TEST(if(fault==4) amount=1;)
    ssize_t done=write(writer,data+at,amount);
    if(done<0) { if(errno==EINTR) continue; fail("write temporary",errno); break; }
    if(!done) { fail("write made no progress",EIO); break; } at+=(size_t)done;
  }
  if(close(writer)<0) fail("close written temporary",errno);
  IO_TEST(if(fault==5) fail("injected close written temporary",EIO);)
  IO_TEST(if(!problem[0] && fault==2 && !test_put(path,"other",5,0)) fail("test target creation",EIO);)
  IO_TEST(if(!problem[0] && fault==6) fail("injected delivery",EACCES);)
  if(!data && !problem[0]) stream_prepare_commit();
  if(!problem[0]) {
    snprintf(reference,sizeof(reference),"/proc/self/fd/%d",keeper);
    if(linkat(AT_FDCWD,reference,dir,leaf,AT_SYMLINK_FOLLOW)<0) fail("deliver without replacement",errno);
    else mark_delivery(data);
  }
  if(keeper>=0 && close(keeper)<0) fail("close temporary identity",errno);
  if(close(dir)<0) fail("close output directory",errno);
  annotate_delivered_problem();
#endif
#endif
  return !problem[0];
}

MOONBIT_FFI_EXPORT int32_t mbsd_deliver_secret(moonbit_bytes_t name,moonbit_bytes_t data) {
  deliver_secret_mode=1;
  return mbsd_deliver(name,data);
}

#ifdef MBSD_IO_TEST
/* Private native white-box support. Uses real files; only fault points are
 * injected. There is no production command or environment switch to set fault. */
static int test_put(const char *name,const char *data,int n,int append) {
#ifdef _WIN32
  wchar_t *p=wide(name); if(!p) return 0;
  HANDLE f=CreateFileW(p,append?FILE_APPEND_DATA:GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,append?OPEN_EXISTING:CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL); free(p);
  if(f==INVALID_HANDLE_VALUE) return 0;
  DWORD done=0; int ok=WriteFile(f,data,n,&done,NULL) && done==(DWORD)n;
  return CloseHandle(f) && ok;
#else
  int f=open(name,O_WRONLY|O_CLOEXEC|(append?O_APPEND:O_CREAT|O_EXCL),0600); if(f<0) return 0;
  int ok=write(f,data,(size_t)n)==n; return close(f)==0 && ok;
#endif
}
MOONBIT_FFI_EXPORT int32_t mbsd_test_fault(int32_t mode,moonbit_bytes_t input,moonbit_bytes_t output) {
  fault=mode;
  if(mode==3 || mode==7 || mode==8) { moonbit_bytes_t b=mbsd_read(input,mode==7?10:1); moonbit_decref(b); }
  else { moonbit_bytes_t b=bytes("abcdef",6); mbsd_deliver(output,b); moonbit_decref(b); }
  fault=0;
  return problem[0]!=0;
}

static int test_matches(const char *path,const char *value) {
  moonbit_bytes_t p=bytes(path,strlen(path)+1),b=mbsd_read(p,100);
  int ok=!problem[0] && (size_t)Moonbit_array_length(b)==strlen(value) && !memcmp(b,value,strlen(value));
  moonbit_decref(b); moonbit_decref(p); return ok;
}
static int test_missing(const char *path) {
#ifdef _WIN32
  wchar_t *p=wide(path); if(!p) return 0; DWORD a=GetFileAttributesW(p),e=GetLastError(); free(p); return a==INVALID_FILE_ATTRIBUTES && e==ERROR_FILE_NOT_FOUND;
#else
  struct stat s; return lstat(path,&s)<0 && errno==ENOENT;
#endif
}
static void test_remove(const char *path,int directory) {
#ifdef _WIN32
  wchar_t *p=wide(path); if(p) { if(directory) RemoveDirectoryW(p); else DeleteFileW(p); free(p); }
#else
  if(directory) rmdir(path); else unlink(path);
#endif
}
MOONBIT_FFI_EXPORT int32_t mbsd_io_contract(int32_t mode) {
  char root[32000],input[32768],output[32768],collision[32768];
  problem[0]=0; fault=0;
#ifdef _WIN32
  wchar_t base[32768],name[32768];
  DWORD count=GetTempPathW(32000,base); if(!count || count>32000) return 101;
  int made=0;
  for(int i=0;i<128;i++) {
    swprintf(name,32768,L"%lsmoonbsdiff-io-%lu-%u",base,(unsigned long)GetCurrentProcessId(),++sequence);
    if(CreateDirectoryW(name,NULL)) { made=1; break; }
    if(GetLastError()!=ERROR_ALREADY_EXISTS) break;
  }
  if(!made || !WideCharToMultiByte(CP_UTF8,0,name,-1,root,sizeof(root),NULL,NULL)) return 102;
#else
  strcpy(root,"/tmp/moonbsdiff-io-XXXXXX"); if(!mkdtemp(root)) return 102;
#endif
  snprintf(input,sizeof(input),"%s/input",root);
  snprintf(output,sizeof(output),"%s/output",root);
  snprintf(collision,sizeof(collision),"%s/.moonbsdiff-collision.tmp",root);
  int result=0;
  if(!test_put(input,mode==8?"ABC":"A",mode==8?3:1,0)) result=103;
  if(mode==1 && !test_put(collision,"existing",8,0)) result=104;
  moonbit_bytes_t a=bytes(input,strlen(input)+1),b=bytes(output,strlen(output)+1);
  if(!result) {
    int failed=mbsd_test_fault(mode,a,b);
    if(failed!=(mode!=1 && mode!=9)) result=105;
    if((mode==3 || mode==8) && !strstr(problem,"read limit")) result=106;
    if(mode==7 && !strstr(problem,"close input")) result=107;
    if(mode==4 && !strstr(problem,"write")) result=108;
    if(mode==5 && !strstr(problem,"close written")) result=109;
    if(mode==6 && !strstr(problem,"delivery")) result=110;
    if(mode==2 && !strstr(problem,"deliver without replacement")) result=111;
  }
  if(!result && !test_matches(input,mode==3?"ABC":mode==8?"ABC":"A")) result=112;
  if(!result && mode==1 && !test_matches(collision,"existing")) result=113;
  if(!result) {
    if(mode==1 || mode==9) { if(!test_matches(output,"abcdef")) result=114; }
    else if(mode==2) { if(!test_matches(output,"other")) result=115; }
    else if(!test_missing(output)) result=116;
  }
  /* Only the initial fixture(s) and a committed output may have names. */
  int entries=0;
#ifdef _WIN32
  wchar_t pattern[32768]; wchar_t *wr=wide(root);
  if(wr) { swprintf(pattern,32768,L"%ls/*",wr); free(wr); WIN32_FIND_DATAW found; HANDLE h=FindFirstFileW(pattern,&found);
    if(h!=INVALID_HANDLE_VALUE) { do { if(wcscmp(found.cFileName,L".") && wcscmp(found.cFileName,L"..")) entries++; } while(FindNextFileW(h,&found)); FindClose(h); }
  }
#else
  DIR *d=opendir(root); if(d) { struct dirent *e; while((e=readdir(d))) if(strcmp(e->d_name,".") && strcmp(e->d_name,"..")) entries++; closedir(d); }
#endif
  if(!result && entries!=(mode==1?3:(mode==2 || mode==9)?2:1)) result=117;
  moonbit_decref(a); moonbit_decref(b);
  test_remove(input,0); test_remove(output,0); if(mode==1) test_remove(collision,0); test_remove(root,1);
  problem[0]=0; return result;
}
#ifdef __linux__
/* Deterministic tests operate exclusively inside a newly owned fixture root. */
MOONBIT_FFI_EXPORT int32_t mbsd_compat_contract(int32_t mode) {
  char root[]="/tmp/moonbsdiff-compat-contract-XXXXXX",input[256],out[256];
  if(!mkdtemp(root)) return 201;
  snprintf(input,sizeof(input),"%s/input",root);snprintf(out,sizeof(out),"%s/output",root);
  problem[0]=0;fault=0;compat_force=1;compat_mutate=0;compat_selected=0;compat_retained=0;compat_last[0]=0;
  int dir=open(root,O_RDONLY|O_DIRECTORY|O_CLOEXEC),result=0;
  if(dir<0 || !test_put(input,"sentinel",8,0)) result=202;
  if(mode==2) {
    compat_mutate=1;
    if(mkdirat(dir,".moonbsdiff-compat-collision",0700)<0) result=203;
    int cd=openat(dir,".moonbsdiff-compat-collision",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    int file=cd>=0?openat(cd,"marker",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600):-1;
    if(file<0 || write(file,"keep",4)!=4) result=204;
    if(file>=0) close(file);
    if(cd>=0) close(cd);
  }
  if(mode==3) compat_mutate=2;
  if(mode==4) compat_mutate=3;
  if(mode==5) compat_mutate=4;
  if(mode==6) fault=4;
  if(mode==7) fault=5;
  if(mode==8) fault=6;
  if(mode==9) compat_force=2;
  if(mode==10) compat_force=3;
  if(mode==11) compat_force=4;
  if(mode==12) fault=9;
  if(mode==13 && chmod(root,0777)<0) result=205;
  if(mode==14 && chmod(root,01777)<0) result=206;
  if(mode==15) fault=10;
  if(mode==16) { compat_force=0;fault=4; }
  if(mode==17) { compat_force=0;fault=5; }
  if(mode==18) compat_mutate=5;
  int success=(mode==1 || mode==2 || mode==10 || mode==12 || mode==14);
  if(!result) {
    moonbit_bytes_t name=bytes(out,strlen(out)+1),data=bytes("abcdef",6);
    int ok=mbsd_deliver(name,data);moonbit_decref(name);moonbit_decref(data);
    if(ok!=success) result=210+mode;
    int selected=(mode==9 || mode==11 || mode==16 || mode==17)?0:1;
    if(compat_selected!=selected) result=240+mode;
    if((mode==4 || mode==5) && (!compat_retained || !strstr(problem,"identity"))) result=270+mode;
    if(mode==18 && (!compat_retained || !strstr(problem,"output already delivered"))) result=298;
    if(mode==9 && !strstr(problem,"anonymous temporary creation")) result=299;
    if(mode==11 && !strstr(problem,"close anonymous")) result=300;
  }
  fault=0;compat_force=0;compat_mutate=0;
  if(!test_matches(input,"sentinel") && !result) result=301;
  if(success && !test_matches(out,"abcdef") && !result) result=302;
  if(mode==3 && !test_matches(out,"other") && !result) result=303;
  if(mode==18 && !test_matches(out,"abcdef") && !result) result=311;
  if(!success && mode!=3 && mode!=18 && !test_missing(out) && !result) result=304;
  if(mode==18) {
    int pd=openat(dir,compat_last,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(pd<0) result=312;
    if(pd>=0) { unlinkat(pd,"payload",0);close(pd); }
    unlinkat(dir,compat_last,AT_REMOVEDIR);
  }
  if(mode==4) {
    int pd=openat(dir,compat_last,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat ps;
    if(pd<0 || fstatat(pd,"payload",&ps,AT_SYMLINK_NOFOLLOW)<0 || !S_ISLNK(ps.st_mode)) result=305;
    if(pd>=0) { unlinkat(pd,"payload",0);close(pd); } /* Our test-injected symlink. */
    unlinkat(dir,compat_last,AT_REMOVEDIR);
  }
  if(mode==5) {
    struct stat named;if(fstatat(dir,compat_last,&named,AT_SYMLINK_NOFOLLOW)<0 || !S_ISDIR(named.st_mode)) result=306;
    int pd=openat(dir,"retained-original",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(pd<0) result=307;
    if(pd>=0) { unlinkat(pd,"payload",0);close(pd); }
    unlinkat(dir,"retained-original",AT_REMOVEDIR);unlinkat(dir,compat_last,AT_REMOVEDIR);
  }
  if(mode==2) {
    char marker[256];snprintf(marker,sizeof(marker),"%s/.moonbsdiff-compat-collision/marker",root);
    if(!test_matches(marker,"keep") && !result) result=308;
    int cd=openat(dir,".moonbsdiff-compat-collision",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if(cd>=0) { unlinkat(cd,"marker",0);close(cd); }
    unlinkat(dir,".moonbsdiff-compat-collision",AT_REMOVEDIR);
  }
  int entries=0;DIR *listing=opendir(root);if(!listing) result=309;
  else { struct dirent *e;while((e=readdir(listing))) if(strcmp(e->d_name,".") && strcmp(e->d_name,"..")) entries++;closedir(listing); }
  if(entries!=(success || mode==3 || mode==18?2:1) && !result) result=310;
  if(dir>=0) { unlinkat(dir,"input",0);unlinkat(dir,"output",0);close(dir); }
  chmod(root,0700);rmdir(root);problem[0]=0;
  return result;
}
#endif
#endif

/* Private synchronous streaming adapter. No product fault/configuration hook.
 * Only this compilation unit owns these handles; callbacks never publish paths. */
#ifdef _WIN32
typedef HANDLE StreamFile;
#define STREAM_INVALID INVALID_HANDLE_VALUE
#else
typedef int StreamFile;
#define STREAM_INVALID (-1)
#endif
static StreamFile stream_inputs[2]={STREAM_INVALID,STREAM_INVALID};
static StreamFile stream_writer=STREAM_INVALID;
static StreamFile stream_copy=STREAM_INVALID;
#ifndef _WIN32
_Static_assert(sizeof(off_t)>=8,"streaming requires 64-bit file offsets");
#endif
static int64_t stream_sizes[2];
static int32_t (*stream_call)(void *);
static void *stream_context;
static void *stream_gate;
static int stream_committed;
IO_TEST(static void interrupt_test_checkpoint(int point);)
IO_TEST(static size_t stream_written;)
static void stream_close_file(StreamFile *file,const char *label) {
  if(*file==STREAM_INVALID) return;
#ifdef _WIN32
  if(!CloseHandle(*file)) fail(label,GetLastError());
#else
  if(close(*file)<0) fail(label,errno);
#endif
  *file=STREAM_INVALID;
}
static void stream_close_inputs(void) {
  for(int i=0;i<2;i++) {
    stream_close_file(&stream_inputs[i],"close stream input");
    stream_sizes[i]=0;
  }
  stream_close_file(&stream_copy,"close private input copy");
}
static void stream_open_file(int i,moonbit_bytes_t path,int64_t cap,const char *limit) {
  if(cap<1 || cap>INT32_MAX) { fail("stream input cap",EINVAL);return; }
#ifdef _WIN32
  wchar_t *name=wide((char*)path);if(!name) return;
  stream_inputs[i]=CreateFileW(name,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
  DWORD open_err=GetLastError();
  free(name);
  if(stream_inputs[i]==INVALID_HANDLE_VALUE) { fail("open/size stream input",open_err);return; }
  LARGE_INTEGER size;
  DWORD ftype=GetFileType(stream_inputs[i]);
  if(ftype!=FILE_TYPE_DISK) {
    DWORD type_err=(ftype==FILE_TYPE_UNKNOWN)?GetLastError():ERROR_INVALID_FUNCTION;
    stream_close_file(&stream_inputs[i],"close non-disk stream input");
    fail("stream input must be a regular disk file",type_err?type_err:ERROR_INVALID_FUNCTION);
    return;
  }
  if(!GetFileSizeEx(stream_inputs[i],&size)) {
    DWORD size_err=GetLastError();
    stream_close_file(&stream_inputs[i],"close unsized stream input");
    fail("open/size stream input",size_err);
    return;
  }
  stream_sizes[i]=size.QuadPart;
#else
  stream_inputs[i]=open((char*)path,O_RDONLY|O_CLOEXEC|O_NONBLOCK);
  struct stat st;
  if(stream_inputs[i]<0) { fail("open/size stream input",errno);return; }
  if(fstat(stream_inputs[i],&st)<0) { int e=errno; stream_close_file(&stream_inputs[i],"close unsized stream input"); fail("open/size stream input",e);return; }
  if(!S_ISREG(st.st_mode)) { stream_close_file(&stream_inputs[i],"close non-regular stream input"); fail("stream input must be a regular file",EINVAL);return; }
  stream_sizes[i]=st.st_size;
#endif
  if(stream_sizes[i]<0 || stream_sizes[i]>cap) limit_fail(limit,(int)cap);
}
MOONBIT_FFI_EXPORT int32_t mbsd_stream_open(moonbit_bytes_t old,moonbit_bytes_t patch,int64_t oldcap,int64_t patchcap) {
  problem[0]=0;
  if(stream_inputs[0]!=STREAM_INVALID || stream_inputs[1]!=STREAM_INVALID || stream_copy!=STREAM_INVALID) {
    fail("stream input handles already open",EBUSY);return 0;
  }
  stream_open_file(0,old,oldcap,"max_old_bytes");
  if(!problem[0]) stream_open_file(1,patch,patchcap,"max_patch_bytes");
  if(problem[0]) stream_close_inputs();
  return !problem[0];
}
/* Called before delivery to open and check the full download once. */
MOONBIT_FFI_EXPORT int32_t mbsd_stream_open_full(moonbit_bytes_t path,int64_t cap) {
  problem[0]=0;
  if(stream_inputs[0]!=STREAM_INVALID || stream_inputs[1]!=STREAM_INVALID || stream_copy!=STREAM_INVALID) {
    fail("stream input handles already open",EBUSY);return 0;
  }
  stream_open_file(0,path,cap,"full target");
  if(problem[0]) stream_close_inputs();
  return !problem[0];
}
/* Open a single installed/current input file bounded by max_old_bytes. */
MOONBIT_FFI_EXPORT int32_t mbsd_stream_open_old(moonbit_bytes_t path,int64_t cap) {
  problem[0]=0;
  if(stream_inputs[0]!=STREAM_INVALID || stream_inputs[1]!=STREAM_INVALID || stream_copy!=STREAM_INVALID) {
    fail("stream input handles already open",EBUSY);return 0;
  }
  stream_open_file(0,path,cap,"max_old_bytes");
  if(problem[0]) stream_close_inputs();
  return !problem[0];
}
/* A verified intermediate handle is already installed as old input. */
MOONBIT_FFI_EXPORT int32_t mbsd_stream_open_next_patch(moonbit_bytes_t patch,int64_t cap) {
  if(stream_inputs[0]==STREAM_INVALID || stream_inputs[1]!=STREAM_INVALID || stream_copy!=STREAM_INVALID)
    fail("stream chain input state",EINVAL);
  if(!problem[0]) {
    stream_open_file(1,patch,cap,"max_patch_bytes");
    if(problem[0]) { stream_close_file(&stream_inputs[1],"close rejected next patch"); stream_sizes[1]=0; }
  }
  return !problem[0];
}
MOONBIT_FFI_EXPORT int64_t mbsd_stream_size(int32_t which) { return which>=0 && which<2?stream_sizes[which]:-1; }
MOONBIT_FFI_EXPORT moonbit_bytes_t mbsd_stream_read(int32_t which,int64_t offset,int32_t count) {
  uint8_t buffer[4096];size_t at=0;
  if(problem[0]) return bytes(NULL,0);
  if(which<0 || which>1 || stream_inputs[which]==STREAM_INVALID || offset<0 || count<0 || count>4096 || offset>stream_sizes[which] || count>stream_sizes[which]-offset) {
    fail("stream read range",EINVAL);return bytes(NULL,0);
  }
  while(at<(size_t)count) {
#ifdef _WIN32
    LARGE_INTEGER pos;pos.QuadPart=offset+(int64_t)at;DWORD done=0;
    if(!SetFilePointerEx(stream_inputs[which],pos,NULL,FILE_BEGIN)) {
      DWORD error=GetLastError();
      fail("seek stream input",error);break;
    }
    BOOL read_ok;
    IO_TEST(if(fault==12) {
      SetLastError(ERROR_ACCESS_DENIED);
      read_ok=TRUE; /* Simulate a successful read of zero bytes. */
    } else)
    read_ok=ReadFile(stream_inputs[which],buffer+at,(DWORD)count-(DWORD)at,&done,NULL);
    if(!read_ok) {
      DWORD error=GetLastError();
      fail("read stream input",error);break;
    }
    if(!done) { fail("premature EOF reading stream input",ERROR_HANDLE_EOF);break; }
#else
    ssize_t done=pread(stream_inputs[which],buffer+at,(size_t)count-at,(off_t)(offset+(int64_t)at));
    if(done<0 && errno==EINTR) continue;
    if(done<=0) { fail("stream read/truncated input",done<0?errno:EIO);break; }
#endif
    at+=(size_t)done;
  }
  return problem[0]?bytes(NULL,0):bytes(buffer,at);
}
/* Private scratch files are accessed only by handle after exclusive creation.
 * Windows denies sharing and removes on handle close. POSIX unlinks the entry
 * in a trusted, anchored temporary directory before writing any content. */
#ifdef __APPLE__
static int open_apple_copy_dir(void) {
  int dir=open("/private/tmp",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if(dir>=0) return dir;
  int first_err=errno;
  const char *env_tmp=getenv("TMPDIR");
  if(!env_tmp || env_tmp[0]!='/') { fail("open input copy directory /private/tmp",first_err); return -1; }
  size_t len=strlen(env_tmp);
  while(len>1 && env_tmp[len-1]=='/') len--;
  if(len==1) { fail("open input copy directory /private/tmp",first_err); return -1; }
  char *copy=malloc(len+1);
  if(!copy) { fail("input copy directory allocation",ENOMEM); return -1; }
  memcpy(copy,env_tmp,len);
  copy[len]=0;
  dir=open(copy,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  int second_err=errno;
  free(copy);
  if(dir<0) fail("open input copy directory",second_err);
  return dir;
}
#endif
MOONBIT_FFI_EXPORT int32_t mbsd_stream_copy_begin(void) {
  if(stream_copy!=STREAM_INVALID) { fail("private input copy already open",EBUSY);return 0; }
#ifdef _WIN32
  wchar_t *path=malloc(32768*sizeof(wchar_t));
  if(!path) { fail("input copy path allocation",ERROR_NOT_ENOUGH_MEMORY);return 0; }
  DWORD n=GetTempPathW(32768,path);
  if(!n) { DWORD e=GetLastError(); free(path); fail("resolve input copy directory",e);return 0; }
  if(n>32000) { free(path); fail("resolve input copy directory",ERROR_BUFFER_OVERFLOW);return 0; }
  for(int attempt=0;attempt<128;attempt++) {
    wchar_t hex[33];
    if(!win_random_hex(hex)) { free(path); return 0; }
    swprintf(path+n,32768-n,L".moonbsdiff-input-%ls.tmp",hex);
    stream_copy=CreateFileW(path,GENERIC_READ|GENERIC_WRITE|DELETE,0,NULL,CREATE_NEW,
                           FILE_ATTRIBUTE_TEMPORARY|FILE_FLAG_DELETE_ON_CLOSE,NULL);
    if(stream_copy!=STREAM_INVALID) { free(path); return 1; }
    DWORD error=GetLastError();
    if(error!=ERROR_FILE_EXISTS && error!=ERROR_ALREADY_EXISTS) {
      free(path); fail("create private input copy",error);return 0;
    }
  }
  free(path);
  fail("input copy name collisions exhausted",ERROR_FILE_EXISTS);
#else
#ifdef __APPLE__
  int dir=open_apple_copy_dir();
  if(dir<0) return 0;
#else
  int dir=open("/tmp",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if(dir<0) { fail("open input copy directory /tmp",errno);return 0; }
#endif
  struct stat parent;
  if(fstat(dir,&parent)<0) fail("inspect input copy directory",errno);
  else if(!S_ISDIR(parent.st_mode) || parent.st_nlink==0 ||
          (parent.st_uid!=0 && parent.st_uid!=geteuid()) ||
          ((parent.st_mode&0022) && !(parent.st_mode&S_ISVTX)))
    fail("input copy directory must be protected or sticky",EPERM);
  char name[80];
  for(int attempt=0;attempt<128 && !problem[0];attempt++) {
    if(!random_name(name)) break;
    stream_copy=openat(dir,name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(stream_copy!=STREAM_INVALID) {
      if(unlinkat(dir,name,0)<0) {
        fail("unlink private input copy",errno);
        retained(name);
      }
      break;
    }
    if(errno!=EEXIST) { fail("create private input copy",errno);break; }
  }
  if(close(dir)<0) fail("close input copy directory",errno);
  if(stream_copy==STREAM_INVALID && !problem[0]) fail("input copy name collisions exhausted",EEXIST);
#endif
  return !problem[0];
}

MOONBIT_FFI_EXPORT int32_t mbsd_stream_copy_write(moonbit_bytes_t data) {
  size_t n=Moonbit_array_length(data),at=0;
  if(n>4096 || stream_copy==STREAM_INVALID) { fail("input copy write range",EINVAL);return 0; }
  while(at<n && !problem[0]) {
#ifdef _WIN32
    DWORD done;
    if(!windows_write(stream_copy,data+at,(DWORD)(n-at),&done,"write private input copy")) break;
#else
    ssize_t done=write(stream_copy,data+at,n-at);
    if(done<0 && errno==EINTR) continue;
    if(done<=0) { fail("write private input copy",done<0?errno:EIO);break; }
#endif
    at+=(size_t)done;
  }
  return !problem[0];
}

/* Probe the open handle for growth beyond the size observed at open. */
MOONBIT_FFI_EXPORT int32_t mbsd_stream_expect_eof(int32_t which) {
  uint8_t extra;
  if(which<0 || which>1 || stream_inputs[which]==STREAM_INVALID) {
    fail("stream input handle",EINVAL);return 0;
  }
#ifdef _WIN32
  LARGE_INTEGER end;end.QuadPart=stream_sizes[which];
  DWORD done=0;
  if(!SetFilePointerEx(stream_inputs[which],end,NULL,FILE_BEGIN) ||
     !ReadFile(stream_inputs[which],&extra,1,&done,NULL)) {
    DWORD error=GetLastError();
    fail("check stream input EOF",error);
  }
  else if(done) fail("input grew beyond verified length",EFBIG);
#else
  ssize_t done;
  do { done=pread(stream_inputs[which],&extra,1,(off_t)stream_sizes[which]); }
  while(done<0 && errno==EINTR);
  if(done<0) fail("check stream input EOF",errno);
  else if(done) fail("input grew beyond verified length",EFBIG);
#endif
  return !problem[0];
}

/* Only a fully verified private copy replaces the source handle. */
MOONBIT_FFI_EXPORT int32_t mbsd_stream_copy_use(int32_t which) {
  if(stream_copy==STREAM_INVALID) {
    fail("input copy handle",EINVAL);return 0;
  }
  if(!mbsd_stream_expect_eof(which)) return 0;
  stream_close_file(&stream_inputs[which],"close original input");
  if(problem[0]) return 0;
  stream_inputs[which]=stream_copy;
  stream_copy=STREAM_INVALID;
  return 1;
}

/* The decoder checked every written byte and the output hash. Keep the
 * exclusive handle, check the length and retire the previous step's inputs. */
MOONBIT_FFI_EXPORT int32_t mbsd_stream_use_intermediate(int64_t expected) {
  if(problem[0]) return 0;
  if(stream_copy==STREAM_INVALID) { fail("missing private intermediate",EINVAL);return 0; }
#ifdef _WIN32
  LARGE_INTEGER size;
  if(!GetFileSizeEx(stream_copy,&size)) { fail("size private intermediate",GetLastError());return 0; }
  int64_t length=size.QuadPart;
#else
  struct stat st;
  if(fstat(stream_copy,&st)<0) { fail("size private intermediate",errno);return 0; }
  int64_t length=st.st_size;
#endif
  if(length!=expected) { fail("private intermediate size mismatch",EINVAL);return 0; }
  for(int i=0;i<2;i++) stream_close_file(&stream_inputs[i],"close previous chain input");
  if(problem[0]) return 0;
  stream_inputs[0]=stream_copy;
  stream_sizes[0]=length;
  stream_sizes[1]=0;
  stream_copy=STREAM_INVALID;
  return 1;
}

MOONBIT_FFI_EXPORT int32_t mbsd_stream_write(moonbit_bytes_t data) {
  size_t n=Moonbit_array_length(data),at=0;
  if(n>4096 || stream_writer==STREAM_INVALID) { fail("stream output chunk",EINVAL);return 0; }
  while(!problem[0] && at<n) {
    size_t amount=n-at;
    IO_TEST(if(fault==9 && amount>2) amount=2;)
    IO_TEST(if(fault==4 && stream_written) { fail("injected stream write",EIO);break; })
    IO_TEST(if(fault==4) amount=1;)
#ifdef _WIN32
    DWORD done=0;
    if(!windows_write(stream_writer,data+at,(DWORD)amount,&done,"stream write")) break;
#else
    ssize_t done=IO_TEST(fault==10?0:)write(stream_writer,data+at,amount);
    if(done<0 && errno==EINTR) continue;
    if(done<=0) { fail("stream write/no progress",done<0?errno:EIO);break; }
#endif
    at+=(size_t)done; IO_TEST(stream_written+=(size_t)done;)
  }
  return !problem[0];
}
#ifdef _WIN32
static int stream_populate(HANDLE writer) {
#else
static int stream_populate(int writer) {
#endif
  stream_writer=writer;
  int ok=stream_call && stream_call(stream_context);
  stream_writer=STREAM_INVALID;
  /* Even an input-close failure must precede publication. */
  stream_close_inputs();
  if(!ok) {
    stream_stopped=1;
    if(!problem[0]) snprintf(problem,sizeof(problem),"stream producer stopped; temporary output not delivered");
  }
  return ok && !problem[0];
}
static int stream_prepare_commit(void) {
  if(!stream_gate) return 1;
  int ok=stream_call(stream_gate);
  if(!ok) {
    stream_stopped=1;
    if(!problem[0]) snprintf(problem,sizeof(problem),"stream cancelled/failed before commit");
  }
  IO_TEST(if(ok) interrupt_test_checkpoint(60);) /* private late-request boundary */
  return ok;
}
static void stream_mark_published(void) { stream_committed=1; }
MOONBIT_FFI_EXPORT int32_t mbsd_stream_published(void) { return stream_committed; }
MOONBIT_FFI_EXPORT int32_t mbsd_stream_deliver(moonbit_bytes_t path,int32_t (*call)(void*),void *context,void *gate) {
  stream_call=call;stream_context=context;stream_gate=gate;IO_TEST(stream_written=0;)stream_committed=0;stream_stopped=0;
  int ok=mbsd_deliver(path,NULL);
  stream_writer=STREAM_INVALID;
  stream_close_inputs(); /* creation failure can occur before populate */
  stream_call=NULL;stream_context=NULL;stream_gate=NULL;stream_stopped=0;
  return ok && !problem[0];
}
MOONBIT_FFI_EXPORT void mbsd_stream_abort(void) { stream_close_inputs(); }
#ifdef MBSD_IO_TEST
/* New delivery lifecycle only: callback writes, close gate, race, cleanup and reuse. */
static int32_t stream_contract_body(void *ignored) {
  (void)ignored;
  moonbit_bytes_t read=mbsd_stream_read(0,0,1);
  int good=Moonbit_array_length(read)==1 && read[0]=='A';moonbit_decref(read);
  moonbit_bytes_t b=bytes("abcdef",6);
  if(good) good=mbsd_stream_write(b);
  moonbit_decref(b);return good;
}
MOONBIT_FFI_EXPORT int32_t mbsd_stream_contract(int32_t mode) {
  char root[32000],input[32768],output[32768];problem[0]=0;fault=0;
#ifdef _WIN32
  wchar_t base[32768],name[32768];DWORD count=GetTempPathW(32000,base);
  if(!count || count>32000) return 301;
  swprintf(name,32768,L"%lsmoonbsdiff-stream-%lu-%u",base,(unsigned long)GetCurrentProcessId(),++sequence);
  if(!CreateDirectoryW(name,NULL) || !WideCharToMultiByte(CP_UTF8,0,name,-1,root,sizeof(root),NULL,NULL)) return 302;
#else
  strcpy(root,"/tmp/moonbsdiff-stream-XXXXXX");if(!mkdtemp(root)) return 302;
#endif
  snprintf(input,sizeof(input),"%s/input",root);snprintf(output,sizeof(output),"%s/output",root);
  int result=0;if(!test_put(input,"A",1,0)) result=303;
  moonbit_bytes_t a=bytes(input,strlen(input)+1),b=bytes(output,strlen(output)+1);
#ifdef __linux__
  if(mode==11) compat_force=1;
#endif
  if(!result && !mbsd_stream_open(a,a,1,1)) result=304;
  fault=mode==11?0:mode;
  if(!result) {
    int ok=mbsd_stream_deliver(b,stream_contract_body,NULL,NULL);
    if(ok!=(mode==9 || mode==11)) result=305;
    if(mode==4 && !strstr(problem,"write")) result=306;
    if(mode==5 && !strstr(problem,"close written")) result=307;
    if(mode==6 && !strstr(problem,"delivery")) result=308;
#ifdef _WIN32
    if(mode==10 && !strstr(problem,"write made no progress (OS error 29)")) result=309;
    if(mode==12 && !strstr(problem,"premature EOF reading stream input (OS error 38)")) result=315;
#else
    if(mode==10 && !strstr(problem,"progress")) result=309;
#endif
    if(mode==2) { if(!test_matches(output,"other")) result=310; }
    else if(mode==9 || mode==11) { if(!test_matches(output,"abcdef")) result=311; }
    else if(!test_missing(output)) result=312;
  }
  test_remove(output,0);fault=0;
#ifdef _WIN32
  if(!result && mode==12) {
    moonbit_bytes_t whole=mbsd_read(a,1);
    if(problem[0] || Moonbit_array_length(whole)!=1 || whole[0]!='A') result=316;
    moonbit_decref(whole);
    if(!result && (!mbsd_stream_open(a,a,1,1) || !mbsd_stream_expect_eof(0))) result=317;
    mbsd_stream_abort();
  }
#endif
  if(!result && (!mbsd_stream_open(a,a,1,1) || !mbsd_stream_deliver(b,stream_contract_body,NULL,NULL) || !test_matches(output,"abcdef"))) result=313;
  test_remove(output,0);test_remove(input,0);
#ifdef _WIN32
  wchar_t *r=wide(root);if(!r || !RemoveDirectoryW(r)) result=314;free(r);
#else
  if(rmdir(root)<0) result=314;
#ifdef __linux__
  compat_force=0;
#endif
#endif
  moonbit_decref(a);moonbit_decref(b);problem[0]=0;return result;
}
#endif

/* Per-operation signal routing, never runtime/IO/cleanup from a handler.
 * Generation tags keep a stale Windows handler from marking a later operation. */
static int interrupt_generation;
IO_TEST(static int interrupt_test_point,interrupt_test_wait;)
#ifdef _WIN32
static volatile LONG interrupt_route;
static BOOL WINAPI stream_console_interrupt(DWORD kind) {
  if(kind!=CTRL_C_EVENT && kind!=CTRL_BREAK_EVENT) return FALSE;
  LONG observed=InterlockedCompareExchange(&interrupt_route,0,0);
  if(!(observed&1)) return FALSE;
  if(!(observed&4)) InterlockedCompareExchange(&interrupt_route,observed|2,observed);
  return TRUE;
}
#else
static volatile sig_atomic_t interrupt_live,interrupt_notified,interrupt_sealed;
static struct sigaction interrupt_previous;
static void stream_signal_interrupt(int number) { (void)number;if(!interrupt_sealed) interrupt_notified=interrupt_live; }
#endif
MOONBIT_FFI_EXPORT int32_t mbsd_interrupt_begin(void) {
  problem[0]=0;stream_committed=0;
  if(interrupt_generation>INT32_MAX-16) { fail("interrupt generation exhausted",EOVERFLOW);return 0; }
#ifdef _WIN32
  if(InterlockedCompareExchange(&interrupt_route,0,0)&1) { fail("interrupt operation already active",EBUSY);return 0; }
  int token=interrupt_generation+8;
  InterlockedExchange(&interrupt_route,token|1);
  if(!SetConsoleCtrlHandler(stream_console_interrupt,TRUE)) {
    InterlockedExchange(&interrupt_route,0);fail("install console interrupt handler",GetLastError());return 0;
  }
#else
  if(interrupt_live) { fail("interrupt operation already active",EBUSY);return 0; }
  sigset_t mask,previous;sigemptyset(&mask);sigaddset(&mask,SIGINT);
  if(sigprocmask(SIG_BLOCK,&mask,&previous)<0) { fail("block SIGINT for install",errno);return 0; }
  struct sigaction action;memset(&action,0,sizeof(action));action.sa_handler=stream_signal_interrupt;sigemptyset(&action.sa_mask);
  if(sigaction(SIGINT,&action,&interrupt_previous)<0) { int e=errno;sigprocmask(SIG_SETMASK,&previous,NULL);fail("install SIGINT handler",e);return 0; }
  int token=interrupt_generation+8;interrupt_notified=0;interrupt_sealed=0;interrupt_live=token;
  if(sigprocmask(SIG_SETMASK,&previous,NULL)<0) {
    int e=errno;interrupt_live=0;sigaction(SIGINT,&interrupt_previous,NULL);fail("restore signal mask after install",e);return 0;
  }
#endif
  interrupt_generation=token;return token;
}
static int interrupt_requested(int token) {
#ifdef _WIN32
  return InterlockedCompareExchange(&interrupt_route,0,0)==(token|3);
#else
  return interrupt_live==token && interrupt_notified==token;
#endif
}
/* Admission is the cancellation/irreversible-work linearization point. */
MOONBIT_FFI_EXPORT int32_t mbsd_interrupt_commit(int32_t token) {
#ifdef _WIN32
  LONG observed=InterlockedCompareExchange(&interrupt_route,token|5,token|1);
  if(observed==(token|1)) return 1;
  if(observed==(token|3)) return 0;
  fail("interrupt commit session mismatch",EINVAL);return -1;
#else
  sigset_t mask,previous;sigemptyset(&mask);sigaddset(&mask,SIGINT);
  if(sigprocmask(SIG_BLOCK,&mask,&previous)<0) { fail("block SIGINT for commit",errno);return -1; }
  if(interrupt_live!=token || interrupt_sealed) {
    sigprocmask(SIG_SETMASK,&previous,NULL);
    fail("interrupt commit session mismatch",EINVAL);
    return -1;
  }
  IO_TEST(interrupt_test_checkpoint(52);) /* private blocked/pending signal regression */
  sigset_t pending;
  if(sigpending(&pending)<0) { int e=errno;sigprocmask(SIG_SETMASK,&previous,NULL);fail("query pending SIGINT",e);return -1; }
  int ready=interrupt_notified!=token && !sigismember(&pending,SIGINT);
  if(ready) interrupt_sealed=1;
  if(sigprocmask(SIG_SETMASK,&previous,NULL)<0) { fail("restore commit signal mask",errno);return -1; }
  return ready;
#endif
}
MOONBIT_FFI_EXPORT int32_t mbsd_interrupt_end(int32_t token) {
#ifdef _WIN32
  if((InterlockedCompareExchange(&interrupt_route,0,0)&~7)!=token) { fail("interrupt session mismatch",EINVAL);return 0; }
  InterlockedExchange(&interrupt_route,token);
  if(!SetConsoleCtrlHandler(stream_console_interrupt,FALSE)) { fail("restore console interrupt handler",GetLastError());return 0; }
#else
  if(interrupt_live!=token) { fail("interrupt session mismatch",EINVAL);return 0; }
  sigset_t mask,previous;sigemptyset(&mask);sigaddset(&mask,SIGINT);
  if(sigprocmask(SIG_BLOCK,&mask,&previous)<0) { fail("block SIGINT for restore",errno);return 0; }
  interrupt_live=0;interrupt_notified=0;
  int restored=sigaction(SIGINT,&interrupt_previous,NULL)==0,restore_error=errno;
  int unblocked=sigprocmask(SIG_SETMASK,&previous,NULL)==0,mask_error=errno;
  if(!restored || !unblocked) { fail("restore SIGINT handler/mask",!restored?restore_error:mask_error);return 0; }
#endif
  return 1;
}
#ifdef MBSD_IO_TEST
/* Only the private test snapshot calls setup. No CLI or environment enables it. */
MOONBIT_FFI_EXPORT void mbsd_interrupt_test_setup(int32_t point,int32_t wait,int32_t injected_fault) {
  interrupt_test_point=point;interrupt_test_wait=wait;fault=injected_fault;
}
static void interrupt_test_checkpoint(int point) {
  if(!interrupt_test_point || interrupt_test_point!=point) return;
  interrupt_test_point=0;
#ifndef _WIN32
  if(point==52) { raise(SIGINT);return; }
#endif
  if(interrupt_test_wait) {
#ifdef _WIN32
    printf("INTERRUPT_READY %lu\n",(unsigned long)GetCurrentProcessId());
#else
    printf("INTERRUPT_READY %ld\n",(long)getpid());
#endif
    fflush(stdout);
    if(interrupt_test_wait>=2) {
      if(getchar()!='!') { fail("private checkpoint handshake",EIO);return; }
      if(interrupt_test_wait==2) return;
#ifdef _WIN32
      stream_console_interrupt(CTRL_C_EVENT);
#else
      stream_signal_interrupt(SIGINT);
#endif
      return;
    }
    for(int i=0;i<4000 && !interrupt_requested(interrupt_generation);i++) {
#ifdef _WIN32
      Sleep(5);
#else
      struct timespec pause={0,5000000};nanosleep(&pause,NULL);
#endif
    }
    if(!interrupt_requested(interrupt_generation)) fail("private interrupt wait timed out",ETIMEDOUT);
  } else {
#ifdef _WIN32
    stream_console_interrupt(CTRL_C_EVENT);
#else
    stream_signal_interrupt(SIGINT);
#endif
  }
}
#endif

MOONBIT_FFI_EXPORT int32_t mbsd_interrupt_poll(int32_t token,int32_t point) {
  IO_TEST(interrupt_test_checkpoint(point);)
  (void)point;
  return interrupt_requested(token);
}

/* Safe cross-platform directory tree helpers (no symlink/reparse traversal). */
#define MBSD_DIR_MAX_ENTRIES 16384u
#define MBSD_DIR_MAX_DEPTH 64
#define MBSD_DIR_MAX_PATH_BYTES 1024u

#ifdef _WIN32
#define MBSD_ERR_INVALID ERROR_INVALID_NAME
#define MBSD_ERR_DEPTH ERROR_BUFFER_OVERFLOW
#else
#define MBSD_ERR_INVALID EINVAL
#define MBSD_ERR_DEPTH ELOOP
#endif

MOONBIT_FFI_EXPORT int32_t mbsd_is_windows(void) {
#ifdef _WIN32
  return 1;
#else
  return 0;
#endif
}

MOONBIT_FFI_EXPORT int32_t mbsd_parent_is_case_insensitive(moonbit_bytes_t output_dir) {
  problem[0]=0;
#ifdef _WIN32
  (void)output_dir;
  return 1;
#else
  const char *leaf=NULL;
  int pfd=pair_parent(output_dir,&leaf);
  if(pfd<0) return -1;
  int ci=is_case_insensitive_dir(pfd);
  if(close(pfd)<0) { fail("close output parent directory",errno); return -1; }
  return ci?1:0;
#endif
}

typedef struct {
  char **items;
  size_t count;
  size_t cap;
  size_t visited;
} DirList;

static void dir_list_free(DirList *list) {
  if(!list) return;
  for(size_t i=0;i<list->count;i++) free(list->items[i]);
  free(list->items);
  list->items=NULL;
  list->count=0;
  list->cap=0;
}

static int dir_entry_name_valid(const unsigned char *s,size_t len) {
  if(!len) return 0;
  if((len==1 && s[0]=='.') || (len==2 && s[0]=='.' && s[1]=='.')) return 0;
  for(size_t i=0;i<len;i++) {
    unsigned char c=s[i];
    if(c<0x20u || c==0x7Fu || c=='/' || c=='\\') return 0;
  }
  return 1;
}

static int validate_rel_path_c(const char *rel,int reject_colon) {
  size_t len=strlen(rel);
  if(!len || len>MBSD_DIR_MAX_PATH_BYTES) {
    fail("invalid relative path",MBSD_ERR_INVALID);
    return 0;
  }
  if(rel[0]=='/' || rel[0]=='\\' || rel[len-1]=='/' || rel[len-1]=='\\') {
    fail("invalid relative path",MBSD_ERR_INVALID);
    return 0;
  }
#ifndef _WIN32
  if(!valid_utf8((const unsigned char *)rel,len)) {
    fail("invalid UTF-8 relative path",EINVAL);
    return 0;
  }
#endif
  int depth=0;
  size_t seg_start=0;
  for(size_t i=0;i<=len;i++) {
    unsigned char c=(i<len)?(unsigned char)rel[i]:(unsigned char)'/';
    if(i<len) {
      if(c<0x20u || c==0x7Fu || c=='\\') {
        fail("invalid relative path",MBSD_ERR_INVALID);
        return 0;
      }
      if(reject_colon && c==':') {
        fail("invalid relative path",MBSD_ERR_INVALID);
        return 0;
      }
    }
    if(c=='/') {
      size_t slen=i-seg_start;
      if(!dir_entry_name_valid((const unsigned char *)(rel+seg_start),slen)) {
        fail("invalid relative path component",MBSD_ERR_INVALID);
        return 0;
      }
      if(i<len && ++depth>MBSD_DIR_MAX_DEPTH) {
        fail("directory depth limit exceeded",MBSD_ERR_DEPTH);
        return 0;
      }
      seg_start=i+1;
    }
  }
  return 1;
}

static int dir_list_push(DirList *list,const char *rel,size_t len) {
  if(!len || len>MBSD_DIR_MAX_PATH_BYTES) {
    fail("relative path exceeds length limit",ENAMETOOLONG);
    return 0;
  }
  if(list->count>=MBSD_DIR_MAX_ENTRIES) {
    fail("directory entry limit exceeded",E2BIG);
    return 0;
  }
  if(list->count==list->cap) {
    size_t next=list->cap?list->cap*2:64;
    if(next>MBSD_DIR_MAX_ENTRIES) next=MBSD_DIR_MAX_ENTRIES;
    char **grown=realloc(list->items,next*sizeof(char*));
    if(!grown) { fail("directory list allocation",ENOMEM); return 0; }
    list->items=grown;
    list->cap=next;
  }
  char *copy=malloc(len+1);
  if(!copy) { fail("directory entry allocation",ENOMEM); return 0; }
  memcpy(copy,rel,len);
  copy[len]=0;
  list->items[list->count++]=copy;
  return 1;
}

static int dir_cmp_paths(const void *a,const void *b) {
  const unsigned char *sa=*(const unsigned char *const *)a;
  const unsigned char *sb=*(const unsigned char *const *)b;
  while(*sa && *sa==*sb) { sa++; sb++; }
  return (int)*sa-(int)*sb;
}

static moonbit_bytes_t dir_list_to_bytes(DirList *list) {
  if(list->count==0) {
    dir_list_free(list);
    return bytes(NULL,0);
  }
  qsort(list->items,list->count,sizeof(char*),dir_cmp_paths);
  size_t total=0;
  for(size_t i=0;i<list->count;i++) {
    size_t l=strlen(list->items[i]);
    if(l>(size_t)INT32_MAX-1u || total>(size_t)INT32_MAX-l-1u) {
      dir_list_free(list);
      fail("directory listing too large",ENOMEM);
      return bytes(NULL,0);
    }
    total+=l+(i+1<list->count?1:0);
  }
  char *joined=malloc(total?total:1);
  if(!joined) {
    dir_list_free(list);
    fail("directory listing allocation",ENOMEM);
    return bytes(NULL,0);
  }
  size_t at=0;
  for(size_t i=0;i<list->count;i++) {
    size_t l=strlen(list->items[i]);
    memcpy(joined+at,list->items[i],l);
    at+=l;
    if(i+1<list->count) joined[at++]='\n';
  }
  moonbit_bytes_t result=bytes(joined,at);
  free(joined);
  dir_list_free(list);
  return result;
}

#ifdef _WIN32
#ifndef WC_ERR_INVALID_CHARS
#define WC_ERR_INVALID_CHARS 0x00000080
#endif

static int win_is_extended_drive_root(const wchar_t *w,size_t len) {
  return len==7 && w[0]==L'\\' && w[1]==L'\\' && (w[2]==L'?' || w[2]==L'.') &&
    w[3]==L'\\' && win_is_ascii_alpha(w[4]) && w[5]==L':' && w[6]==L'\\';
}

static int win_is_bare_drive_or_volume(const wchar_t *w,size_t len) {
  if(len==2 && win_is_ascii_alpha(w[0]) && w[1]==L':') return 1;
  if(len==6 && w[0]==L'\\' && w[1]==L'\\' && (w[2]==L'?' || w[2]==L'.') &&
     w[3]==L'\\' && win_is_ascii_alpha(w[4]) && w[5]==L':') return 1;
  return 0;
}

static int win_is_device_namespace(const wchar_t *w,size_t len) {
  return (len==3 || (len>=4 && (w[3]==L'\\' || w[3]==L'/'))) &&
    (w[0]==L'\\' || w[0]==L'/') && (w[1]==L'\\' || w[1]==L'/') && w[2]==L'.';
}

static wchar_t *win_trim_dir_path(const char *utf8_path) {
  wchar_t *w=wide(utf8_path);
  if(!w) return NULL;
  size_t len=wcslen(w);
  if(!len) { free(w); fail("empty directory path",ERROR_INVALID_NAME); return NULL; }
  if(win_is_device_namespace(w,len)) {
    free(w);
    fail("Win32 device namespace paths (\\\\.\\) are unsupported",ERROR_INVALID_NAME);
    return NULL;
  }
  if(win_is_bare_drive_or_volume(w,len)) {
    free(w);
    fail("bare drive or volume path without root separator is unsupported",ERROR_INVALID_NAME);
    return NULL;
  }
  while(len>1 && (w[len-1]==L'\\' || w[len-1]==L'/')) {
    if(len==3 && win_is_ascii_alpha(w[0]) && w[1]==L':') break;
    if(win_is_extended_drive_root(w,len)) break;
    w[--len]=0;
  }
  if(win_is_bare_drive_or_volume(w,len)) {
    free(w);
    fail("bare drive or volume path without root separator is unsupported",ERROR_INVALID_NAME);
    return NULL;
  }
  return w;
}

/* Convert a trimmed Win32 directory path to an extended-length \\?\ path so
 * Win32 CreateFileW/GetFileAttributesW never strip trailing dots/spaces on
 * enumerated child entries (preventing file. -> file silent aliasing). */
static wchar_t *win_to_extended_dir_path(const wchar_t *wpath) {
  size_t wlen=wcslen(wpath);
  if(win_is_device_namespace(wpath,wlen)) {
    fail("Win32 device namespace paths (\\\\.\\) are unsupported",ERROR_INVALID_NAME);
    return NULL;
  }
  if(wlen>=4 && wpath[0]==L'\\' && wpath[1]==L'\\' && wpath[2]==L'?' && wpath[3]==L'\\') {
    if(wcschr(wpath,L'/')) {
      fail("forward slashes are unsupported in extended paths",ERROR_INVALID_NAME);
      return NULL;
    }
    wchar_t *copy=malloc((wlen+1)*sizeof(wchar_t));
    if(!copy) { fail("path allocation",ERROR_NOT_ENOUGH_MEMORY); return NULL; }
    memcpy(copy,wpath,(wlen+1)*sizeof(wchar_t));
    return copy;
  }
  wchar_t *full=malloc(32768*sizeof(wchar_t));
  if(!full) { fail("path allocation",ERROR_NOT_ENOUGH_MEMORY); return NULL; }
  DWORD flen=GetFullPathNameW(wpath,32768,full,NULL);
  DWORD ferr=GetLastError();
  if(!flen || flen>=32768) {
    free(full);
    fail("resolve directory path",flen?ERROR_FILENAME_EXCED_RANGE:ferr);
    return NULL;
  }
  if(win_is_device_namespace(full,(size_t)flen)) {
    free(full);
    fail("Win32 device namespace paths (\\\\.\\) are unsupported",ERROR_INVALID_NAME);
    return NULL;
  }
  wchar_t *ext=NULL;
  if(flen>=4 && full[0]==L'\\' && full[1]==L'\\' && full[2]==L'?' && full[3]==L'\\') {
    ext=full;
  } else if(flen>=2 && full[0]==L'\\' && full[1]==L'\\') {
    size_t need=8u+(size_t)(flen-2u)+1u;
    if(need>32768u) { free(full); fail("resolve directory path",ERROR_FILENAME_EXCED_RANGE); return NULL; }
    ext=malloc(need*sizeof(wchar_t));
    if(!ext) { free(full); fail("path allocation",ERROR_NOT_ENOUGH_MEMORY); return NULL; }
    memcpy(ext,L"\\\\?\\UNC\\",8u*sizeof(wchar_t));
    memcpy(ext+8,full+2,(size_t)(flen-2u+1u)*sizeof(wchar_t));
    free(full);
  } else {
    size_t need=4u+(size_t)flen+1u;
    if(need>32768u) { free(full); fail("resolve directory path",ERROR_FILENAME_EXCED_RANGE); return NULL; }
    ext=malloc(need*sizeof(wchar_t));
    if(!ext) { free(full); fail("path allocation",ERROR_NOT_ENOUGH_MEMORY); return NULL; }
    memcpy(ext,L"\\\\?\\",4u*sizeof(wchar_t));
    memcpy(ext+4,full,(size_t)(flen+1u)*sizeof(wchar_t));
    free(full);
  }
  size_t elen=wcslen(ext);
  while(elen>1 && ext[elen-1]==L'\\' && !win_is_extended_drive_root(ext,elen)) ext[--elen]=0;
  return ext;
}

static wchar_t *win_join_segment(const wchar_t *base,const wchar_t *seg) {
  size_t blen=wcslen(base);
  size_t slen=wcslen(seg);
  int has_sep=(blen>0 && (base[blen-1]==L'\\' || base[blen-1]==L'/'));
  wchar_t *joined=malloc((blen+slen+2)*sizeof(wchar_t));
  if(!joined) { fail("path allocation",ERROR_NOT_ENOUGH_MEMORY); return NULL; }
  memcpy(joined,base,blen*sizeof(wchar_t));
  size_t at=blen;
  if(!has_sep) joined[at++]=L'\\';
  memcpy(joined+at,seg,(slen+1)*sizeof(wchar_t));
  return joined;
}

static int win_same_file_id(const BY_HANDLE_FILE_INFORMATION *a,const BY_HANDLE_FILE_INFORMATION *b) {
  return a->dwVolumeSerialNumber==b->dwVolumeSerialNumber &&
    a->nFileIndexHigh==b->nFileIndexHigh &&
    a->nFileIndexLow==b->nFileIndexLow;
}

static int win_is_root_dir(const wchar_t *p,size_t len) {
  if(len==1 && (p[0]==L'\\' || p[0]==L'/')) return 1;
  if(len==3 && win_is_ascii_alpha(p[0]) && p[1]==L':' && (p[2]==L'\\' || p[2]==L'/')) return 1;
  if(win_is_extended_drive_root(p,len)) return 1;
  if(len>=5 && p[0]==L'\\' && p[1]==L'\\') {
    size_t start=2;
    if(len>=8 && (p[2]==L'?' || p[2]==L'.') && p[3]==L'\\' &&
       (p[4]==L'U' || p[4]==L'u') && (p[5]==L'N' || p[5]==L'n') &&
       (p[6]==L'C' || p[6]==L'c') && p[7]==L'\\') {
      start=8;
    } else if(p[2]==L'?' || p[2]==L'.') {
      return 0;
    }
    size_t seps=0;
    for(size_t i=start;i<len;i++) if(p[i]==L'\\') seps++;
    if(seps<=1) return 1;
  }
  return 0;
}

static int win_strip_parent(wchar_t *p) {
  size_t len=wcslen(p);
  while(len>1 && p[len-1]==L'\\' && !win_is_root_dir(p,len)) p[--len]=0;
  if(win_is_root_dir(p,len)) return 0;
  wchar_t *slash=wcsrchr(p,L'\\');
  if(!slash) return 0;
  size_t pos=(size_t)(slash-p);
  if(pos==0 ||
     (pos==2 && win_is_ascii_alpha(p[0]) && p[1]==L':') ||
     (pos==6 && p[0]==L'\\' && p[1]==L'\\' && (p[2]==L'?' || p[2]==L'.') &&
      p[3]==L'\\' && win_is_ascii_alpha(p[4]) && p[5]==L':')) {
    p[pos+1]=0;
    return 1;
  }
  p[pos]=0;
  return 1;
}

static int win_check_ancestor_chain(const wchar_t *start_dir,const BY_HANDLE_FILE_INFORMATION *input_info) {
  size_t slen=wcslen(start_dir);
  if(slen>=32768) { fail("ancestor path too long",ERROR_FILENAME_EXCED_RANGE); return 0; }
  wchar_t *walk=malloc(32768*sizeof(wchar_t));
  if(!walk) { fail("ancestor path allocation",ERROR_NOT_ENOUGH_MEMORY); return 0; }
  memcpy(walk,start_dir,(slen+1)*sizeof(wchar_t));
  for(int hops=0;hops<4096;hops++) {
    HANDLE h=CreateFileW(walk,FILE_READ_ATTRIBUTES,
                         FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,
                         OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
    if(h==INVALID_HANDLE_VALUE) {
      DWORD e=GetLastError();
      free(walk);
      fail(hops==0?"open output parent directory":"inspect output ancestor directory",e);
      return 0;
    }
    BY_HANDLE_FILE_INFORMATION wi;
    BOOL got=GetFileInformationByHandle(h,&wi);
    DWORD ge=GetLastError();
    if(!CloseHandle(h)) {
      DWORD ce=GetLastError();
      free(walk);
      fail("close output ancestor directory",ce);
      return 0;
    }
    if(!got) { free(walk); fail("inspect output ancestor directory",ge); return 0; }
    if(hops==0 && !(wi.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
      free(walk);
      fail("output parent is not a directory",ERROR_DIRECTORY);
      return 0;
    }
    if((wi.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && win_same_file_id(&wi,input_info)) {
      free(walk);
      fail("output directory must not be inside an input directory",ERROR_ALREADY_EXISTS);
      return 0;
    }
    if(!win_strip_parent(walk)) break;
  }
  free(walk);
  return 1;
}

static int win_walk_dir(const wchar_t *wdir,const char *rel_prefix,size_t prefix_len,int depth,DirList *out) {
  if(depth>MBSD_DIR_MAX_DEPTH) {
    fail("directory depth limit exceeded",ERROR_BUFFER_OVERFLOW);
    return 0;
  }
  size_t wdir_len=wcslen(wdir);
  int has_sep=(wdir_len>0 && (wdir[wdir_len-1]==L'\\' || wdir[wdir_len-1]==L'/'));
  wchar_t *pattern=malloc((wdir_len+3)*sizeof(wchar_t));
  WIN32_FIND_DATAW *fdat=malloc(sizeof(*fdat));
  if(!pattern || !fdat) {
    free(pattern); free(fdat);
    fail("directory walk allocation",ERROR_NOT_ENOUGH_MEMORY);
    return 0;
  }
  memcpy(pattern,wdir,wdir_len*sizeof(wchar_t));
  size_t pat_at=wdir_len;
  if(!has_sep) pattern[pat_at++]=L'\\';
  pattern[pat_at++]=L'*';
  pattern[pat_at]=0;
  HANDLE h=FindFirstFileW(pattern,fdat);
  free(pattern);
  if(h==INVALID_HANDLE_VALUE) {
    DWORD e=GetLastError();
    free(fdat);
    if(e==ERROR_FILE_NOT_FOUND || e==ERROR_NO_MORE_FILES) return 1;
    fail("list directory",e);
    return 0;
  }
  int ok=1;
  do {
    if(wcscmp(fdat->cFileName,L".")==0 || wcscmp(fdat->cFileName,L"..")==0) continue;
    if(out->visited>=MBSD_DIR_MAX_ENTRIES) {
      fail("directory entry limit exceeded",ERROR_BUFFER_OVERFLOW);
      ok=0; break;
    }
    out->visited++;
    if(fdat->dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
      fail("symlink or reparse point encountered in directory tree",ERROR_ACCESS_DENIED);
      ok=0; break;
    }
    if(fdat->dwFileAttributes & FILE_ATTRIBUTE_DEVICE) {
      fail("device file encountered in directory tree",ERROR_INVALID_FUNCTION);
      ok=0; break;
    }
    if(!valid_utf16(fdat->cFileName)) {
      fail("invalid UTF-16 filename in directory tree",ERROR_NO_UNICODE_TRANSLATION);
      ok=0; break;
    }
    int need=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,fdat->cFileName,-1,NULL,0,NULL,NULL);
    if(need<=0) {
      fail("UTF-8 filename conversion",GetLastError());
      ok=0; break;
    }
    if(need==1) {
      fail("empty filename in directory tree",ERROR_INVALID_NAME);
      ok=0; break;
    }
    size_t name_len=(size_t)(need-1);
    size_t child_rel_len=prefix_len?(prefix_len+1+name_len):name_len;
    if(child_rel_len>MBSD_DIR_MAX_PATH_BYTES) {
      fail("relative path exceeds length limit",ERROR_FILENAME_EXCED_RANGE);
      ok=0; break;
    }
    char *child_rel=malloc(child_rel_len+1);
    if(!child_rel) { fail("relative path allocation",ERROR_NOT_ENOUGH_MEMORY); ok=0; break; }
    char *name_dst=child_rel;
    if(prefix_len) {
      memcpy(child_rel,rel_prefix,prefix_len);
      child_rel[prefix_len]='/';
      name_dst=child_rel+prefix_len+1;
    }
    if(!WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,fdat->cFileName,-1,name_dst,need,NULL,NULL)) {
      DWORD e=GetLastError();
      free(child_rel);
      fail("UTF-8 filename conversion",e);
      ok=0; break;
    }
    if(!dir_entry_name_valid((const unsigned char *)name_dst,name_len)) {
      free(child_rel);
      fail("invalid filename character in directory tree",ERROR_INVALID_NAME);
      ok=0; break;
    }
    wchar_t *child_w=win_join_segment(wdir,fdat->cFileName);
    if(!child_w) {
      free(child_rel);
      ok=0; break;
    }
    DWORD cattrs=GetFileAttributesW(child_w);
    if(cattrs==INVALID_FILE_ATTRIBUTES) {
      DWORD e=GetLastError();
      free(child_w); free(child_rel);
      fail("inspect directory entry",e);
      ok=0; break;
    }
    if(cattrs & FILE_ATTRIBUTE_REPARSE_POINT) {
      free(child_w); free(child_rel);
      fail("symlink or reparse point encountered in directory tree",ERROR_ACCESS_DENIED);
      ok=0; break;
    }
    if(cattrs & FILE_ATTRIBUTE_DEVICE) {
      free(child_w); free(child_rel);
      fail("device file encountered in directory tree",ERROR_INVALID_FUNCTION);
      ok=0; break;
    }
    if(cattrs & FILE_ATTRIBUTE_DIRECTORY) {
      ok=win_walk_dir(child_w,child_rel,child_rel_len,depth+1,out);
      free(child_w); free(child_rel);
      if(!ok) break;
    } else {
      free(child_w);
      ok=dir_list_push(out,child_rel,child_rel_len);
      free(child_rel);
      if(!ok) break;
    }
  } while(FindNextFileW(h,fdat));
  if(ok) {
    DWORD end_err=GetLastError();
    if(end_err!=ERROR_NO_MORE_FILES) {
      fail("list directory",end_err);
      ok=0;
    }
  }
  FindClose(h);
  free(fdat);
  return ok && !problem[0];
}
#else
static char *posix_trim_dir_path(const char *raw) {
  size_t len=strlen(raw);
  if(!len) { fail("empty directory path",EINVAL); return NULL; }
  while(len>1 && raw[len-1]=='/') len--;
  char *copy=malloc(len+1);
  if(!copy) { fail("directory path allocation",ENOMEM); return NULL; }
  memcpy(copy,raw,len);
  copy[len]=0;
  return copy;
}

static int posix_walk_dir(int dir_fd,const char *rel_prefix,size_t prefix_len,int depth,DirList *out) {
  if(depth>MBSD_DIR_MAX_DEPTH) {
    close(dir_fd);
    fail("directory depth limit exceeded",ELOOP);
    return 0;
  }
  DIR *d=fdopendir(dir_fd);
  if(!d) {
    int e=errno;
    close(dir_fd);
    fail("open directory stream",e);
    return 0;
  }
  int dfd=dirfd(d);
  if(dfd<0) {
    int e=errno;
    closedir(d);
    fail("inspect directory descriptor",e);
    return 0;
  }
  int ok=1;
  for(;;) {
    errno=0;
    struct dirent *ent=readdir(d);
    if(!ent) {
      if(errno!=0) { fail("read directory entry",errno); ok=0; }
      break;
    }
    if(strcmp(ent->d_name,".")==0 || strcmp(ent->d_name,"..")==0) continue;
    if(out->visited>=MBSD_DIR_MAX_ENTRIES) {
      fail("directory entry limit exceeded",E2BIG);
      ok=0; break;
    }
    out->visited++;
    size_t name_len=strlen(ent->d_name);
    if(!valid_utf8((const unsigned char *)ent->d_name,name_len) ||
       !dir_entry_name_valid((const unsigned char *)ent->d_name,name_len)) {
      fail("invalid filename in directory tree",EINVAL);
      ok=0; break;
    }
    size_t child_rel_len=prefix_len?(prefix_len+1+name_len):name_len;
    if(child_rel_len>MBSD_DIR_MAX_PATH_BYTES) {
      fail("relative path exceeds length limit",ENAMETOOLONG);
      ok=0; break;
    }
    struct stat est;
    if(fstatat(dfd,ent->d_name,&est,AT_SYMLINK_NOFOLLOW)<0) {
      fail("stat directory entry",errno);
      ok=0; break;
    }
    if(S_ISLNK(est.st_mode)) {
      fail("symlink encountered in directory tree",ELOOP);
      ok=0; break;
    }
    char *child_rel=malloc(child_rel_len+1);
    if(!child_rel) { fail("relative path allocation",ENOMEM); ok=0; break; }
    if(prefix_len) {
      memcpy(child_rel,rel_prefix,prefix_len);
      child_rel[prefix_len]='/';
      memcpy(child_rel+prefix_len+1,ent->d_name,name_len+1);
    } else {
      memcpy(child_rel,ent->d_name,name_len+1);
    }
    if(S_ISDIR(est.st_mode)) {
      int sub_fd=openat(dfd,ent->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
      if(sub_fd<0) {
        int e=errno;
        free(child_rel);
        fail("open subdirectory",e);
        ok=0; break;
      }
      struct stat sub_st;
      if(fstat(sub_fd,&sub_st)<0 || !S_ISDIR(sub_st.st_mode) || !same_inode(&sub_st,&est)) {
        close(sub_fd);
        free(child_rel);
        fail("subdirectory changed during traversal",ESTALE);
        ok=0; break;
      }
      ok=posix_walk_dir(sub_fd,child_rel,child_rel_len,depth+1,out);
      free(child_rel);
      if(!ok) break;
    } else if(S_ISREG(est.st_mode)) {
      ok=dir_list_push(out,child_rel,child_rel_len);
      free(child_rel);
      if(!ok) break;
    } else {
      free(child_rel);
      fail("non-regular file encountered in directory tree",EINVAL);
      ok=0; break;
    }
  }
  if(closedir(d)<0) { fail("close directory stream",errno); ok=0; }
  return ok && !problem[0];
}
#endif

MOONBIT_FFI_EXPORT int32_t mbsd_dir_output_check(moonbit_bytes_t input_dir,moonbit_bytes_t output_dir) {
  problem[0]=0;
#ifdef _WIN32
  wchar_t *wout=wide((const char *)output_dir);
  if(!wout) return 0;
  if(!win_validate_output_path(wout)) { free(wout); return 0; }
  const wchar_t *raw_leaf=wout;
  for(const wchar_t *q=wout;*q;q++) if(*q==L'\\' || *q==L'/') raw_leaf=q+1;
  if(!*raw_leaf || wcscmp(raw_leaf,L".")==0 || wcscmp(raw_leaf,L"..")==0) {
    free(wout);
    fail("invalid output directory name",ERROR_INVALID_NAME);
    return 0;
  }
  wchar_t *full=malloc(32768*sizeof(wchar_t));
  wchar_t *final_parent=malloc(32768*sizeof(wchar_t));
  if(!full || !final_parent) {
    free(wout); free(full); free(final_parent);
    fail("output directory path allocation",ERROR_NOT_ENOUGH_MEMORY);
    return 0;
  }
  DWORD flen=GetFullPathNameW(wout,32768,full,NULL);
  DWORD ferr=GetLastError();
  free(wout);
  if(!flen || flen>=32768) {
    free(full); free(final_parent);
    fail("resolve output directory",flen?ERROR_FILENAME_EXCED_RANGE:ferr);
    return 0;
  }
  wchar_t *slash=wcsrchr(full,L'\\');
  if(!slash || !slash[1]) {
    free(full); free(final_parent);
    fail("invalid output directory name",ERROR_INVALID_NAME);
    return 0;
  }
  slash[1]=0;
  HANDLE ph=CreateFileW(full,FILE_READ_ATTRIBUTES,
                        FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,
                        OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
  if(ph==INVALID_HANDLE_VALUE) {
    DWORD pe=GetLastError();
    free(full); free(final_parent);
    fail("open output parent directory",pe);
    return 0;
  }
  BY_HANDLE_FILE_INFORMATION pi;
  BOOL got_pi=GetFileInformationByHandle(ph,&pi);
  DWORD pi_err=GetLastError();
  final_parent[0]=0;
  if(got_pi) {
    DWORD fn=GetFinalPathNameByHandleW(ph,final_parent,32768,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
    if(fn==0 || fn>=32768) final_parent[0]=0;
  }
  if(!CloseHandle(ph)) {
    DWORD ce=GetLastError();
    free(full); free(final_parent);
    fail("close output parent directory",ce);
    return 0;
  }
  if(!got_pi) {
    free(full); free(final_parent);
    fail("inspect output parent directory",pi_err);
    return 0;
  }
  if(!(pi.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
    free(full); free(final_parent);
    fail("output parent is not a directory",ERROR_DIRECTORY);
    return 0;
  }
  wchar_t *winp=win_trim_dir_path((const char *)input_dir);
  if(!winp) { free(full); free(final_parent); return 0; }
  HANDLE ih=CreateFileW(winp,FILE_READ_ATTRIBUTES,
                        FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,
                        OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
  DWORD ierr=GetLastError();
  free(winp);
  if(ih==INVALID_HANDLE_VALUE) {
    free(full); free(final_parent);
    if(ierr==ERROR_FILE_NOT_FOUND || ierr==ERROR_PATH_NOT_FOUND) return 1;
    fail("inspect input directory",ierr);
    return 0;
  }
  BY_HANDLE_FILE_INFORMATION ii;
  BOOL got_ii=GetFileInformationByHandle(ih,&ii);
  DWORD ii_err=GetLastError();
  if(!CloseHandle(ih)) {
    DWORD ce=GetLastError();
    free(full); free(final_parent);
    fail("close input directory",ce);
    return 0;
  }
  if(!got_ii) {
    free(full); free(final_parent);
    fail("inspect input directory",ii_err);
    return 0;
  }
  if(!(ii.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
    free(full); free(final_parent);
    return 1;
  }
  if(win_same_file_id(&pi,&ii)) {
    free(full); free(final_parent);
    fail("output directory must not be inside an input directory",ERROR_ALREADY_EXISTS);
    return 0;
  }
  int ok=win_check_ancestor_chain(full,&ii);
  if(ok && final_parent[0]) ok=win_check_ancestor_chain(final_parent,&ii);
  free(full); free(final_parent);
  return ok && !problem[0];
#else
  const char *out_path=(const char *)output_dir;
  size_t out_len=strlen(out_path);
  if(!out_len || out_path[out_len-1]=='/') {
    fail("invalid output directory name",EINVAL);
    return 0;
  }
  const char *leaf=NULL;
  int cur_fd=pair_parent(output_dir,&leaf);
  if(cur_fd<0) return 0;
  char *inp=posix_trim_dir_path((const char *)input_dir);
  if(!inp) { close(cur_fd); return 0; }
  struct stat ist;
  if(stat(inp,&ist)<0) {
    int e=errno;
    free(inp);
    if(close(cur_fd)<0) { fail("close output parent directory",errno); return 0; }
    if(e==ENOENT || e==ENOTDIR) return 1;
    fail("inspect input directory",e);
    return 0;
  }
  free(inp);
  if(!S_ISDIR(ist.st_mode)) {
    if(close(cur_fd)<0) { fail("close output parent directory",errno); return 0; }
    return 1;
  }
  int ok=1;
  for(int hops=0;hops<4096;hops++) {
    struct stat cst;
    if(fstat(cur_fd,&cst)<0) { fail("inspect output ancestor directory",errno); ok=0; break; }
    if(same_inode(&cst,&ist)) {
      fail("output directory must not be inside an input directory",EEXIST);
      ok=0; break;
    }
    int up_fd=openat(cur_fd,"..",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if(up_fd<0) { fail("walk output ancestor directory",errno); ok=0; break; }
    struct stat ust;
    if(fstat(up_fd,&ust)<0) {
      int e=errno;
      close(up_fd);
      fail("inspect output ancestor directory",e);
      ok=0; break;
    }
    if(same_inode(&ust,&cst)) {
      if(close(up_fd)<0) { fail("close output ancestor directory",errno); ok=0; }
      break;
    }
    if(close(cur_fd)<0) {
      int e=errno;
      close(up_fd);
      fail("close output ancestor directory",e);
      ok=0; break;
    }
    cur_fd=up_fd;
  }
  if(close(cur_fd)<0) { fail("close output ancestor directory",errno); ok=0; }
  return ok && !problem[0];
#endif
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mbsd_dir_list(moonbit_bytes_t dir_path) {
  problem[0]=0;
  DirList list={NULL,0,0,0};
#ifdef _WIN32
  wchar_t *wraw=win_trim_dir_path((const char *)dir_path);
  if(!wraw) return bytes(NULL,0);
  wchar_t *wroot=win_to_extended_dir_path(wraw);
  free(wraw);
  if(!wroot) return bytes(NULL,0);
  DWORD attrs=GetFileAttributesW(wroot);
  if(attrs==INVALID_FILE_ATTRIBUTES) {
    DWORD e=GetLastError();
    free(wroot);
    fail("inspect directory",e);
    return bytes(NULL,0);
  }
  if(attrs & FILE_ATTRIBUTE_REPARSE_POINT) {
    free(wroot);
    fail("directory path must not be a symlink or reparse point",ERROR_ACCESS_DENIED);
    return bytes(NULL,0);
  }
  if(!(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
    free(wroot);
    fail("path is not a directory",ERROR_DIRECTORY);
    return bytes(NULL,0);
  }
  int ok=win_walk_dir(wroot,"",0,0,&list);
  free(wroot);
#else
  char *root=posix_trim_dir_path((const char *)dir_path);
  if(!root) return bytes(NULL,0);
  struct stat rst;
  if(lstat(root,&rst)<0) {
    int e=errno;
    free(root);
    fail("inspect directory",e);
    return bytes(NULL,0);
  }
  if(S_ISLNK(rst.st_mode)) {
    free(root);
    fail("directory path must not be a symlink",ELOOP);
    return bytes(NULL,0);
  }
  if(!S_ISDIR(rst.st_mode)) {
    free(root);
    fail("path is not a directory",ENOTDIR);
    return bytes(NULL,0);
  }
  int rfd=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  int open_err=errno;
  free(root);
  if(rfd<0) { fail("open directory",open_err); return bytes(NULL,0); }
  struct stat fst;
  if(fstat(rfd,&fst)<0 || !S_ISDIR(fst.st_mode) || !same_inode(&fst,&rst)) {
    close(rfd);
    fail("directory changed on open",ESTALE);
    return bytes(NULL,0);
  }
  int ok=posix_walk_dir(rfd,"",0,0,&list);
#endif
  if(!ok || problem[0]) {
    dir_list_free(&list);
    return bytes(NULL,0);
  }
  return dir_list_to_bytes(&list);
}

/* List regular files directly inside root_dir/rel_subdir, rejecting any
 * symlink/reparse point, device/non-regular file, or subdirectory (even empty).
 * Returns empty bytes without error when rel_subdir does not exist. */
MOONBIT_FFI_EXPORT moonbit_bytes_t mbsd_dir_list_flat(moonbit_bytes_t root_dir,moonbit_bytes_t rel_subdir) {
  problem[0]=0;
  const char *sub=(const char *)rel_subdir;
  size_t sub_len=strlen(sub);
  if(!sub_len || sub_len>MBSD_DIR_MAX_PATH_BYTES ||
     !dir_entry_name_valid((const unsigned char *)sub,sub_len) ||
     strchr(sub,':')!=NULL) {
    fail("invalid subdirectory name",MBSD_ERR_INVALID);
    return bytes(NULL,0);
  }
  DirList list={NULL,0,0,0};
#ifdef _WIN32
  wchar_t *wraw=win_trim_dir_path((const char *)root_dir);
  if(!wraw) return bytes(NULL,0);
  wchar_t *wroot=win_to_extended_dir_path(wraw);
  free(wraw);
  if(!wroot) return bytes(NULL,0);
  DWORD rattrs=GetFileAttributesW(wroot);
  if(rattrs==INVALID_FILE_ATTRIBUTES) {
    DWORD e=GetLastError();
    free(wroot);
    fail("inspect directory",e);
    return bytes(NULL,0);
  }
  if(rattrs & FILE_ATTRIBUTE_REPARSE_POINT) {
    free(wroot);
    fail("directory path must not be a symlink or reparse point",ERROR_ACCESS_DENIED);
    return bytes(NULL,0);
  }
  if(!(rattrs & FILE_ATTRIBUTE_DIRECTORY)) {
    free(wroot);
    fail("path is not a directory",ERROR_DIRECTORY);
    return bytes(NULL,0);
  }
  wchar_t *wsub_name=wide(sub);
  if(!wsub_name) { free(wroot); return bytes(NULL,0); }
  wchar_t *wsub=win_join_segment(wroot,wsub_name);
  free(wroot);
  free(wsub_name);
  if(!wsub) return bytes(NULL,0);
  DWORD sattrs=GetFileAttributesW(wsub);
  if(sattrs==INVALID_FILE_ATTRIBUTES) {
    DWORD e=GetLastError();
    free(wsub);
    if(e==ERROR_FILE_NOT_FOUND || e==ERROR_PATH_NOT_FOUND) return bytes(NULL,0);
    fail("inspect directory",e);
    return bytes(NULL,0);
  }
  if(sattrs & FILE_ATTRIBUTE_REPARSE_POINT) {
    free(wsub);
    fail("directory path must not be a symlink or reparse point",ERROR_ACCESS_DENIED);
    return bytes(NULL,0);
  }
  if(!(sattrs & FILE_ATTRIBUTE_DIRECTORY)) {
    free(wsub);
    fail("path is not a directory",ERROR_DIRECTORY);
    return bytes(NULL,0);
  }
  wchar_t *pattern=win_join_segment(wsub,L"*");
  WIN32_FIND_DATAW *fdat=malloc(sizeof(*fdat));
  if(!pattern || !fdat) {
    free(wsub); free(pattern); free(fdat);
    fail("directory walk allocation",ERROR_NOT_ENOUGH_MEMORY);
    return bytes(NULL,0);
  }
  HANDLE h=FindFirstFileW(pattern,fdat);
  free(pattern);
  if(h==INVALID_HANDLE_VALUE) {
    DWORD e=GetLastError();
    free(wsub); free(fdat);
    if(e==ERROR_FILE_NOT_FOUND || e==ERROR_NO_MORE_FILES) return bytes(NULL,0);
    fail("list directory",e);
    return bytes(NULL,0);
  }
  int ok=1;
  do {
    if(wcscmp(fdat->cFileName,L".")==0 || wcscmp(fdat->cFileName,L"..")==0) continue;
    if(list.visited>=MBSD_DIR_MAX_ENTRIES) {
      fail("directory entry limit exceeded",ERROR_BUFFER_OVERFLOW);
      ok=0; break;
    }
    list.visited++;
    if(fdat->dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
      fail("symlink or reparse point encountered in directory tree",ERROR_ACCESS_DENIED);
      ok=0; break;
    }
    if(fdat->dwFileAttributes & FILE_ATTRIBUTE_DEVICE) {
      fail("device file encountered in directory tree",ERROR_INVALID_FUNCTION);
      ok=0; break;
    }
    if(fdat->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      fail("unexpected subdirectory in blobs directory",ERROR_DIRECTORY);
      ok=0; break;
    }
    if(!valid_utf16(fdat->cFileName)) {
      fail("invalid UTF-16 filename in directory tree",ERROR_NO_UNICODE_TRANSLATION);
      ok=0; break;
    }
    int need=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,fdat->cFileName,-1,NULL,0,NULL,NULL);
    if(need<=0) {
      fail("UTF-8 filename conversion",GetLastError());
      ok=0; break;
    }
    if(need==1) {
      fail("empty filename in directory tree",ERROR_INVALID_NAME);
      ok=0; break;
    }
    size_t name_len=(size_t)(need-1);
    char *utf8_name=malloc(name_len+1);
    if(!utf8_name) { fail("directory entry allocation",ERROR_NOT_ENOUGH_MEMORY); ok=0; break; }
    if(!WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,fdat->cFileName,-1,utf8_name,need,NULL,NULL)) {
      DWORD e=GetLastError();
      free(utf8_name);
      fail("UTF-8 filename conversion",e);
      ok=0; break;
    }
    if(!dir_entry_name_valid((const unsigned char *)utf8_name,name_len)) {
      free(utf8_name);
      fail("invalid filename character in directory tree",ERROR_INVALID_NAME);
      ok=0; break;
    }
    wchar_t *child_w=win_join_segment(wsub,fdat->cFileName);
    if(!child_w) { free(utf8_name); ok=0; break; }
    DWORD cattrs=GetFileAttributesW(child_w);
    free(child_w);
    if(cattrs==INVALID_FILE_ATTRIBUTES) {
      DWORD e=GetLastError();
      free(utf8_name);
      fail("inspect directory entry",e);
      ok=0; break;
    }
    if(cattrs & FILE_ATTRIBUTE_REPARSE_POINT) {
      free(utf8_name);
      fail("symlink or reparse point encountered in directory tree",ERROR_ACCESS_DENIED);
      ok=0; break;
    }
    if(cattrs & FILE_ATTRIBUTE_DEVICE) {
      free(utf8_name);
      fail("device file encountered in directory tree",ERROR_INVALID_FUNCTION);
      ok=0; break;
    }
    if(cattrs & FILE_ATTRIBUTE_DIRECTORY) {
      free(utf8_name);
      fail("unexpected subdirectory in blobs directory",ERROR_DIRECTORY);
      ok=0; break;
    }
    ok=dir_list_push(&list,utf8_name,name_len);
    free(utf8_name);
    if(!ok) break;
  } while(FindNextFileW(h,fdat));
  if(ok) {
    DWORD end_err=GetLastError();
    if(end_err!=ERROR_NO_MORE_FILES) {
      fail("list directory",end_err);
      ok=0;
    }
  }
  FindClose(h);
  free(fdat);
  free(wsub);
#else
  if(!valid_utf8((const unsigned char *)sub,sub_len)) {
    fail("invalid UTF-8 subdirectory name",EINVAL);
    return bytes(NULL,0);
  }
  char *root=posix_trim_dir_path((const char *)root_dir);
  if(!root) return bytes(NULL,0);
  struct stat rst;
  if(lstat(root,&rst)<0) {
    int e=errno;
    free(root);
    fail("inspect directory",e);
    return bytes(NULL,0);
  }
  if(S_ISLNK(rst.st_mode)) {
    free(root);
    fail("directory path must not be a symlink",ELOOP);
    return bytes(NULL,0);
  }
  if(!S_ISDIR(rst.st_mode)) {
    free(root);
    fail("path is not a directory",ENOTDIR);
    return bytes(NULL,0);
  }
  int rfd=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  int open_err=errno;
  free(root);
  if(rfd<0) { fail("open directory",open_err); return bytes(NULL,0); }
  struct stat fst;
  if(fstat(rfd,&fst)<0 || !S_ISDIR(fst.st_mode) || !same_inode(&fst,&rst)) {
    close(rfd);
    fail("directory changed on open",ESTALE);
    return bytes(NULL,0);
  }
  struct stat bst;
  if(fstatat(rfd,sub,&bst,AT_SYMLINK_NOFOLLOW)<0) {
    int e=errno;
    close(rfd);
    if(e==ENOENT) return bytes(NULL,0);
    fail("inspect directory",e);
    return bytes(NULL,0);
  }
  if(S_ISLNK(bst.st_mode)) {
    close(rfd);
    fail("directory path must not be a symlink",ELOOP);
    return bytes(NULL,0);
  }
  if(!S_ISDIR(bst.st_mode)) {
    close(rfd);
    fail("path is not a directory",ENOTDIR);
    return bytes(NULL,0);
  }
  int sfd=openat(rfd,sub,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  int serr=errno;
  close(rfd);
  if(sfd<0) { fail("open directory",serr); return bytes(NULL,0); }
  struct stat sfst;
  if(fstat(sfd,&sfst)<0 || !S_ISDIR(sfst.st_mode) || !same_inode(&sfst,&bst)) {
    close(sfd);
    fail("directory changed on open",ESTALE);
    return bytes(NULL,0);
  }
  DIR *d=fdopendir(sfd);
  if(!d) {
    int e=errno;
    close(sfd);
    fail("open directory stream",e);
    return bytes(NULL,0);
  }
  int dfd=dirfd(d);
  if(dfd<0) {
    int e=errno;
    closedir(d);
    fail("inspect directory descriptor",e);
    return bytes(NULL,0);
  }
  int ok=1;
  for(;;) {
    errno=0;
    struct dirent *ent=readdir(d);
    if(!ent) {
      if(errno!=0) { fail("read directory entry",errno); ok=0; }
      break;
    }
    if(strcmp(ent->d_name,".")==0 || strcmp(ent->d_name,"..")==0) continue;
    if(list.visited>=MBSD_DIR_MAX_ENTRIES) {
      fail("directory entry limit exceeded",E2BIG);
      ok=0; break;
    }
    list.visited++;
    size_t name_len=strlen(ent->d_name);
    if(!valid_utf8((const unsigned char *)ent->d_name,name_len) ||
       !dir_entry_name_valid((const unsigned char *)ent->d_name,name_len)) {
      fail("invalid filename in directory tree",EINVAL);
      ok=0; break;
    }
    struct stat est;
    if(fstatat(dfd,ent->d_name,&est,AT_SYMLINK_NOFOLLOW)<0) {
      fail("stat directory entry",errno);
      ok=0; break;
    }
    if(S_ISLNK(est.st_mode)) {
      fail("symlink encountered in directory tree",ELOOP);
      ok=0; break;
    }
    if(S_ISDIR(est.st_mode)) {
      fail("unexpected subdirectory in blobs directory",EISDIR);
      ok=0; break;
    }
    if(!S_ISREG(est.st_mode)) {
      fail("non-regular file encountered in directory tree",EINVAL);
      ok=0; break;
    }
    ok=dir_list_push(&list,ent->d_name,name_len);
    if(!ok) break;
  }
  if(closedir(d)<0) { fail("close directory stream",errno); ok=0; }
#endif
  if(!ok || problem[0]) {
    dir_list_free(&list);
    return bytes(NULL,0);
  }
  return dir_list_to_bytes(&list);
}

/* Anchored relative file reader rejecting root, intermediate-dir, and leaf
 * symlinks/reparse points and enforcing a hard byte cap on the opened handle. */
MOONBIT_FFI_EXPORT moonbit_bytes_t mbsd_read_rel_nosymlink(
    moonbit_bytes_t root_dir,moonbit_bytes_t rel_path,int32_t cap) {
  problem[0]=0;
  if(cap<0) { fail("negative read cap",EINVAL); return bytes(NULL,0); }
  const char *rel=(const char *)rel_path;
#ifdef _WIN32
  if(!validate_rel_path_c(rel,1)) return bytes(NULL,0);
  wchar_t *wraw=win_trim_dir_path((const char *)root_dir);
  if(!wraw) return bytes(NULL,0);
  wchar_t *cur=win_to_extended_dir_path(wraw);
  free(wraw);
  if(!cur) return bytes(NULL,0);
  DWORD rattrs=GetFileAttributesW(cur);
  if(rattrs==INVALID_FILE_ATTRIBUTES) {
    DWORD e=GetLastError();
    free(cur);
    fail("inspect directory",e);
    return bytes(NULL,0);
  }
  if(rattrs & FILE_ATTRIBUTE_REPARSE_POINT) {
    free(cur);
    fail("directory path must not be a symlink or reparse point",ERROR_ACCESS_DENIED);
    return bytes(NULL,0);
  }
  if(!(rattrs & FILE_ATTRIBUTE_DIRECTORY)) {
    free(cur);
    fail("path is not a directory",ERROR_DIRECTORY);
    return bytes(NULL,0);
  }
  const char *seg=rel;
  const char *slash=NULL;
  while((slash=strchr(seg,'/'))!=NULL) {
    size_t slen=(size_t)(slash-seg);
    char *comp=malloc(slen+1);
    if(!comp) { free(cur); fail("directory component allocation",ERROR_NOT_ENOUGH_MEMORY); return bytes(NULL,0); }
    memcpy(comp,seg,slen);
    comp[slen]=0;
    wchar_t *wcomp=wide(comp);
    free(comp);
    if(!wcomp) { free(cur); return bytes(NULL,0); }
    wchar_t *joined=win_join_segment(cur,wcomp);
    free(wcomp);
    free(cur);
    if(!joined) return bytes(NULL,0);
    cur=joined;
    DWORD cattrs=GetFileAttributesW(cur);
    if(cattrs==INVALID_FILE_ATTRIBUTES) {
      DWORD e=GetLastError();
      free(cur);
      fail("inspect subdirectory",e);
      return bytes(NULL,0);
    }
    if(cattrs & FILE_ATTRIBUTE_REPARSE_POINT) {
      free(cur);
      fail("symlink or reparse point encountered in directory path",ERROR_ACCESS_DENIED);
      return bytes(NULL,0);
    }
    if(!(cattrs & FILE_ATTRIBUTE_DIRECTORY)) {
      free(cur);
      fail("path component is not a directory",ERROR_DIRECTORY);
      return bytes(NULL,0);
    }
    seg=slash+1;
  }
  wchar_t *wleaf=wide(seg);
  if(!wleaf) { free(cur); return bytes(NULL,0); }
  wchar_t *leaf_path=win_join_segment(cur,wleaf);
  free(wleaf);
  free(cur);
  if(!leaf_path) return bytes(NULL,0);
  HANDLE f=CreateFileW(leaf_path,GENERIC_READ,
                       FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,
                       OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,NULL);
  DWORD open_err=GetLastError();
  if(f==INVALID_HANDLE_VALUE) {
    DWORD lattrs=GetFileAttributesW(leaf_path);
    free(leaf_path);
    if(lattrs!=INVALID_FILE_ATTRIBUTES && (lattrs & FILE_ATTRIBUTE_REPARSE_POINT)) {
      fail("file must not be a symlink or reparse point",ERROR_ACCESS_DENIED);
    } else if(lattrs!=INVALID_FILE_ATTRIBUTES && (lattrs & FILE_ATTRIBUTE_DIRECTORY)) {
      fail("input must be a regular disk file",ERROR_INVALID_FUNCTION);
    } else {
      fail("open input",open_err);
    }
    return bytes(NULL,0);
  }
  free(leaf_path);
  unsigned char *buffer=NULL; size_t used=0,capacity=0;
  BY_HANDLE_FILE_INFORMATION fi;
  LARGE_INTEGER size;
  DWORD ftype=GetFileType(f);
  if(!GetFileInformationByHandle(f,&fi)) fail("stat regular input",GetLastError());
  else if(fi.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) fail("file must not be a symlink or reparse point",ERROR_ACCESS_DENIED);
  else if(fi.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_DEVICE)) fail("input must be a regular disk file",ERROR_INVALID_FUNCTION);
  else if(ftype!=FILE_TYPE_DISK) {
    DWORD type_err=(ftype==FILE_TYPE_UNKNOWN)?GetLastError():ERROR_INVALID_FUNCTION;
    fail("input must be a regular disk file",type_err?type_err:ERROR_INVALID_FUNCTION);
  } else if(!GetFileSizeEx(f,&size)) fail("stat regular input",GetLastError());
  else if(size.QuadPart>cap) limit_fail("input size",cap);
  while(!problem[0]) {
    unsigned char chunk[4096];
    size_t room=(size_t)cap-used;
    size_t request=room<sizeof(chunk)?room+1:sizeof(chunk);
    DWORD got=0;
    if(!ReadFile(f,chunk,(DWORD)request,&got,NULL)) {
      DWORD error=GetLastError();
      fail("read input",error);
      break;
    }
    if(!got) break;
    if((size_t)got>room) { limit_fail("read limit",cap); break; }
    size_t wanted=used+(size_t)got;
    if(wanted>capacity) {
      size_t next=capacity?capacity:((size_t)cap<4096?(size_t)cap:4096);
      while(next<wanted) next=next>(size_t)cap/2?(size_t)cap:next*2;
      unsigned char *grown=realloc(buffer,next);
      if(!grown) { fail("read buffer allocation",ENOMEM); break; }
      buffer=grown; capacity=next;
    }
    memcpy(buffer+used,chunk,(size_t)got); used=wanted;
  }
  if(!CloseHandle(f)) fail("close input",GetLastError());
  moonbit_bytes_t result=problem[0]?bytes(NULL,0):bytes(buffer,used);
  free(buffer);
  return result;
#else
  if(!validate_rel_path_c(rel,0)) return bytes(NULL,0);
  char *root=posix_trim_dir_path((const char *)root_dir);
  if(!root) return bytes(NULL,0);
  struct stat rst;
  if(lstat(root,&rst)<0) {
    int e=errno;
    free(root);
    fail("inspect directory",e);
    return bytes(NULL,0);
  }
  if(S_ISLNK(rst.st_mode)) {
    free(root);
    fail("directory path must not be a symlink",ELOOP);
    return bytes(NULL,0);
  }
  if(!S_ISDIR(rst.st_mode)) {
    free(root);
    fail("path is not a directory",ENOTDIR);
    return bytes(NULL,0);
  }
  int cur_fd=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  int open_err=errno;
  free(root);
  if(cur_fd<0) { fail("open directory",open_err); return bytes(NULL,0); }
  struct stat fst;
  if(fstat(cur_fd,&fst)<0 || !S_ISDIR(fst.st_mode) || !same_inode(&fst,&rst)) {
    close(cur_fd);
    fail("directory changed on open",ESTALE);
    return bytes(NULL,0);
  }
  const char *seg=rel;
  const char *slash=NULL;
  while((slash=strchr(seg,'/'))!=NULL) {
    size_t slen=(size_t)(slash-seg);
    char *comp=malloc(slen+1);
    if(!comp) { close(cur_fd); fail("directory component allocation",ENOMEM); return bytes(NULL,0); }
    memcpy(comp,seg,slen);
    comp[slen]=0;
    int next_fd=openat(cur_fd,comp,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    int nerr=errno;
    if(next_fd<0) {
      struct stat cst;
      if(nerr==ELOOP || (fstatat(cur_fd,comp,&cst,AT_SYMLINK_NOFOLLOW)==0 && S_ISLNK(cst.st_mode))) {
        fail("symlink encountered in directory path",ELOOP);
      } else {
        fail("open subdirectory",nerr);
      }
      free(comp);
      close(cur_fd);
      return bytes(NULL,0);
    }
    free(comp);
    struct stat nst;
    if(fstat(next_fd,&nst)<0 || !S_ISDIR(nst.st_mode)) {
      close(next_fd);
      close(cur_fd);
      fail("subdirectory changed on open",ESTALE);
      return bytes(NULL,0);
    }
    if(close(cur_fd)<0) {
      int e=errno;
      close(next_fd);
      fail("close parent directory",e);
      return bytes(NULL,0);
    }
    cur_fd=next_fd;
    seg=slash+1;
  }
  int f=openat(cur_fd,seg,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
  int lerr=errno;
  if(f<0) {
    struct stat lst;
    if(lerr==ELOOP || (fstatat(cur_fd,seg,&lst,AT_SYMLINK_NOFOLLOW)==0 && S_ISLNK(lst.st_mode))) {
      fail("file must not be a symlink",ELOOP);
    } else {
      fail("open input",lerr);
    }
    close(cur_fd);
    return bytes(NULL,0);
  }
  if(close(cur_fd)<0) {
    int e=errno;
    close(f);
    fail("close parent directory",e);
    return bytes(NULL,0);
  }
  unsigned char *buffer=NULL; size_t used=0,capacity=0;
  struct stat st;
  if(fstat(f,&st)<0) fail("stat input",errno);
  else if(!S_ISREG(st.st_mode)) fail("input must be a regular file",EINVAL);
  else if(st.st_size>cap) limit_fail("input size",cap);
  while(!problem[0]) {
    unsigned char chunk[4096];
    size_t room=(size_t)cap-used;
    size_t request=room<sizeof(chunk)?room+1:sizeof(chunk);
    ssize_t got=read(f,chunk,request);
    if(got<0) { if(errno==EINTR) continue; fail("read input",errno); break; }
    if(!got) break;
    if((size_t)got>room) { limit_fail("read limit",cap); break; }
    size_t wanted=used+(size_t)got;
    if(wanted>capacity) {
      size_t next=capacity?capacity:((size_t)cap<4096?(size_t)cap:4096);
      while(next<wanted) next=next>(size_t)cap/2?(size_t)cap:next*2;
      unsigned char *grown=realloc(buffer,next);
      if(!grown) { fail("read buffer allocation",ENOMEM); break; }
      buffer=grown; capacity=next;
    }
    memcpy(buffer+used,chunk,(size_t)got); used=wanted;
  }
  if(close(f)<0) fail("close input",errno);
  moonbit_bytes_t result=problem[0]?bytes(NULL,0):bytes(buffer,used);
  free(buffer);
  return result;
#endif
}

MOONBIT_FFI_EXPORT int32_t mbsd_dir_exists_nosymlink(moonbit_bytes_t dir_path) {
  problem[0]=0;
#ifdef _WIN32
  wchar_t *w=win_trim_dir_path((const char *)dir_path);
  if(!w) return -1;
  DWORD attrs=GetFileAttributesW(w);
  DWORD e=GetLastError();
  free(w);
  if(attrs==INVALID_FILE_ATTRIBUTES) {
    if(e==ERROR_FILE_NOT_FOUND || e==ERROR_PATH_NOT_FOUND) return 0;
    fail("inspect directory",e);
    return -1;
  }
  if(attrs & FILE_ATTRIBUTE_REPARSE_POINT) {
    fail("directory path must not be a symlink or reparse point",ERROR_ACCESS_DENIED);
    return -1;
  }
  if(!(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
    fail("path is not a directory",ERROR_DIRECTORY);
    return -1;
  }
  return 1;
#else
  char *p=posix_trim_dir_path((const char *)dir_path);
  if(!p) return -1;
  struct stat st;
  if(lstat(p,&st)<0) {
    int e=errno;
    free(p);
    if(e==ENOENT) return 0;
    fail("inspect directory",e);
    return -1;
  }
  free(p);
  if(S_ISLNK(st.st_mode)) {
    fail("directory path must not be a symlink",ELOOP);
    return -1;
  }
  if(!S_ISDIR(st.st_mode)) {
    fail("path is not a directory",ENOTDIR);
    return -1;
  }
  return 1;
#endif
}

MOONBIT_FFI_EXPORT int32_t mbsd_file_nosymlink_check(moonbit_bytes_t file_path) {
  problem[0]=0;
#ifdef _WIN32
  wchar_t *w=wide((const char *)file_path);
  if(!w) return 0;
  DWORD attrs=GetFileAttributesW(w);
  DWORD e=GetLastError();
  free(w);
  if(attrs==INVALID_FILE_ATTRIBUTES) {
    fail("inspect file",e);
    return 0;
  }
  if(attrs & FILE_ATTRIBUTE_REPARSE_POINT) {
    fail("file must not be a symlink or reparse point",ERROR_ACCESS_DENIED);
    return 0;
  }
  if(attrs & (FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_DEVICE)) {
    fail("path is not a regular file",ERROR_INVALID_FUNCTION);
    return 0;
  }
  return 1;
#else
  struct stat st;
  if(lstat((const char *)file_path,&st)<0) {
    fail("inspect file",errno);
    return 0;
  }
  if(S_ISLNK(st.st_mode)) {
    fail("file must not be a symlink",ELOOP);
    return 0;
  }
  if(!S_ISREG(st.st_mode)) {
    fail("path is not a regular file",EINVAL);
    return 0;
  }
  return 1;
#endif
}

MOONBIT_FFI_EXPORT int32_t mbsd_mkdir_new(moonbit_bytes_t dir_path) {
  problem[0]=0;
#ifdef _WIN32
  wchar_t *w=wide((const char *)dir_path);
  if(!w) return 0;
  if(!win_validate_output_path(w)) { free(w); return 0; }
  if(!CreateDirectoryW(w,NULL)) {
    DWORD e=GetLastError();
    free(w);
    fail("create output directory",e);
    return 0;
  }
  DWORD attrs=GetFileAttributesW(w);
  DWORD e=GetLastError();
  free(w);
  if(attrs==INVALID_FILE_ATTRIBUTES) {
    fail("verify created output directory",e);
    return 0;
  }
  if((attrs & FILE_ATTRIBUTE_REPARSE_POINT) || !(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
    fail("created output directory identity invalid",ERROR_ACCESS_DENIED);
    return 0;
  }
  return 1;
#else
  const char *path=(const char *)dir_path;
  size_t len=strlen(path);
  if(!len || path[len-1]=='/') {
    fail("invalid output directory name",EINVAL);
    return 0;
  }
  const char *slash=strrchr(path,'/');
  const char *leaf=slash?slash+1:path;
  if(!*leaf || strcmp(leaf,".")==0 || strcmp(leaf,"..")==0) {
    fail("invalid output directory name",EINVAL);
    return 0;
  }
  if(mkdir(path,0755)<0) {
    fail("create output directory",errno);
    return 0;
  }
  struct stat st;
  if(lstat(path,&st)<0) {
    fail("verify created output directory",errno);
    return 0;
  }
  if(!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
    fail("verify created output directory",ESTALE);
    return 0;
  }
  return 1;
#endif
}

MOONBIT_FFI_EXPORT int32_t mbsd_mkdir_parents(moonbit_bytes_t root_dir,moonbit_bytes_t rel_path) {
  problem[0]=0;
  const char *rel=(const char *)rel_path;
#ifdef _WIN32
  if(!validate_rel_path_c(rel,1)) return 0;
#else
  if(!validate_rel_path_c(rel,0)) return 0;
#endif
  const char *last_slash=strrchr(rel,'/');
#ifdef _WIN32
  wchar_t *cur=win_trim_dir_path((const char *)root_dir);
  if(!cur) return 0;
  DWORD rattrs=GetFileAttributesW(cur);
  if(rattrs==INVALID_FILE_ATTRIBUTES) {
    DWORD e=GetLastError();
    free(cur);
    fail("inspect output root directory",e);
    return 0;
  }
  if((rattrs & FILE_ATTRIBUTE_REPARSE_POINT) || !(rattrs & FILE_ATTRIBUTE_DIRECTORY)) {
    free(cur);
    fail("output root must be a non-symlink directory",ERROR_ACCESS_DENIED);
    return 0;
  }
  if(!last_slash) { free(cur); return 1; }
  int depth=0;
  const char *seg=rel;
  while(seg<last_slash) {
    const char *next=strchr(seg,'/');
    if(!next || next>last_slash) break;
    size_t slen=(size_t)(next-seg);
    if(++depth>MBSD_DIR_MAX_DEPTH) {
      free(cur);
      fail("directory depth limit exceeded",ERROR_BUFFER_OVERFLOW);
      return 0;
    }
    char *comp=malloc(slen+1);
    if(!comp) { free(cur); fail("directory component allocation",ERROR_NOT_ENOUGH_MEMORY); return 0; }
    memcpy(comp,seg,slen);
    comp[slen]=0;
    wchar_t *wcomp=wide(comp);
    free(comp);
    if(!wcomp) { free(cur); return 0; }
    wchar_t *joined=win_join_segment(cur,wcomp);
    free(wcomp);
    free(cur);
    if(!joined) return 0;
    cur=joined;
    DWORD cattrs=GetFileAttributesW(cur);
    if(cattrs==INVALID_FILE_ATTRIBUTES) {
      DWORD e=GetLastError();
      if(e!=ERROR_FILE_NOT_FOUND) {
        free(cur);
        fail("inspect output subdirectory",e);
        return 0;
      }
      if(!CreateDirectoryW(cur,NULL)) {
        DWORD ce=GetLastError();
        if(ce!=ERROR_ALREADY_EXISTS) {
          free(cur);
          fail("create output subdirectory",ce);
          return 0;
        }
      }
      cattrs=GetFileAttributesW(cur);
      if(cattrs==INVALID_FILE_ATTRIBUTES) {
        DWORD ve=GetLastError();
        free(cur);
        fail("verify output subdirectory",ve);
        return 0;
      }
    }
    if(cattrs & FILE_ATTRIBUTE_REPARSE_POINT) {
      free(cur);
      fail("symlink or reparse point in output path",ERROR_ACCESS_DENIED);
      return 0;
    }
    if(!(cattrs & FILE_ATTRIBUTE_DIRECTORY)) {
      free(cur);
      fail("output path component is not a directory",ERROR_DIRECTORY);
      return 0;
    }
    seg=next+1;
  }
  free(cur);
  return 1;
#else
  char *root=posix_trim_dir_path((const char *)root_dir);
  if(!root) return 0;
  struct stat rst;
  if(lstat(root,&rst)<0) {
    int e=errno;
    free(root);
    fail("inspect output root directory",e);
    return 0;
  }
  if(S_ISLNK(rst.st_mode) || !S_ISDIR(rst.st_mode)) {
    free(root);
    fail("output root must be a non-symlink directory",ELOOP);
    return 0;
  }
  int cur_fd=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  int open_err=errno;
  free(root);
  if(cur_fd<0) { fail("open output root directory",open_err); return 0; }
  struct stat fst;
  if(fstat(cur_fd,&fst)<0 || !S_ISDIR(fst.st_mode) || !same_inode(&fst,&rst)) {
    close(cur_fd);
    fail("output root changed on open",ESTALE);
    return 0;
  }
  if(!last_slash) {
    if(close(cur_fd)<0) { fail("close output root directory",errno); return 0; }
    return 1;
  }
  int depth=0;
  const char *seg=rel;
  while(seg<last_slash) {
    const char *next=strchr(seg,'/');
    if(!next || next>last_slash) break;
    size_t slen=(size_t)(next-seg);
    if(++depth>MBSD_DIR_MAX_DEPTH) {
      close(cur_fd);
      fail("directory depth limit exceeded",ELOOP);
      return 0;
    }
    char *comp=malloc(slen+1);
    if(!comp) { close(cur_fd); fail("directory component allocation",ENOMEM); return 0; }
    memcpy(comp,seg,slen);
    comp[slen]=0;
    if(mkdirat(cur_fd,comp,0755)<0 && errno!=EEXIST) {
      int e=errno;
      free(comp); close(cur_fd);
      fail("create output subdirectory",e);
      return 0;
    }
    struct stat cst;
    if(fstatat(cur_fd,comp,&cst,AT_SYMLINK_NOFOLLOW)<0) {
      int e=errno;
      free(comp); close(cur_fd);
      fail("stat output subdirectory",e);
      return 0;
    }
    if(S_ISLNK(cst.st_mode) || !S_ISDIR(cst.st_mode)) {
      free(comp); close(cur_fd);
      fail("output path component is a symlink or non-directory",ELOOP);
      return 0;
    }
    int next_fd=openat(cur_fd,comp,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    int nerr=errno;
    free(comp);
    if(next_fd<0) {
      close(cur_fd);
      fail("open output subdirectory",nerr);
      return 0;
    }
    struct stat nst;
    if(fstat(next_fd,&nst)<0 || !S_ISDIR(nst.st_mode) || !same_inode(&nst,&cst)) {
      close(next_fd); close(cur_fd);
      fail("output subdirectory changed on open",ESTALE);
      return 0;
    }
    close(cur_fd);
    cur_fd=next_fd;
    seg=next+1;
  }
  if(close(cur_fd)<0) { fail("close output subdirectory",errno); return 0; }
  return 1;
#endif
}
