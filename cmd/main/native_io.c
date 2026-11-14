/* Original native-only CLI adapter. SPDX-License-Identifier: BSD-2-Clause */
#if !defined(_WIN32) && !defined(__linux__)
#error "MoonBSDiff CLI adapter supports Windows and Linux only"
#endif
#ifndef _WIN32
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#endif
#include "moonbit.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stddef.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <dirent.h>
#include <sys/random.h>
#include <sys/vfs.h>
#include <linux/magic.h>
#endif

static char problem[256];
/* Set only by the private white-box entrypoint below. No environment/CLI hook. */
static int fault;
#ifdef _WIN32
static unsigned sequence;
#endif
static void fail(const char *op, unsigned long code) {
  if (!problem[0]) snprintf(problem,sizeof(problem),"%s (OS error %lu)",op,code);
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
MOONBIT_FFI_EXPORT void mbsd_stderr(moonbit_bytes_t data) {
  size_t n=Moonbit_array_length(data),at=0;
  while(at<n) { size_t k=fwrite(data+at,1,n-at,stderr); if(!k) break; at+=k; }
  fflush(stderr);
}
#ifdef _WIN32
static wchar_t *wide(const char *s) {
  int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s,-1,NULL,0);
  if(n<=0 || n>32768) { fail("UTF-8 path conversion",GetLastError()); return NULL; }
  wchar_t *p=malloc((size_t)n*sizeof(wchar_t));
  if(!p) { fail("path allocation",ERROR_NOT_ENOUGH_MEMORY); return NULL; }
  if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s,-1,p,n)) { fail("UTF-8 path conversion",GetLastError()); free(p); return NULL; }
  return p;
}
#endif
/* Windows arguments must not depend on the runtime's MinGW ANSI fallback. */
#ifdef _WIN32
static LPWSTR *cli_argv;
static int cli_argc;
#endif
MOONBIT_FFI_EXPORT int32_t mbsd_arg_count(void) {
#ifdef _WIN32
  typedef LPWSTR *(WINAPI *parse_args)(LPCWSTR,int*);
  HMODULE dll=LoadLibraryW(L"shell32.dll");
  if(!dll) { fail("load command-line parser",GetLastError()); return -2; }
  parse_args parse=(parse_args)GetProcAddress(dll,"CommandLineToArgvW");
  if(parse) cli_argv=parse(GetCommandLineW(),&cli_argc);
  if(!cli_argv) fail("parse Unicode command line",GetLastError());
  FreeLibrary(dll);
  return cli_argv?cli_argc:-2;
#else
  return -1;
#endif
}
MOONBIT_FFI_EXPORT moonbit_string_t mbsd_arg(int32_t i) {
#ifdef _WIN32
  if(!cli_argv || i<0 || i>=cli_argc) return moonbit_make_string(0,0);
  int n=(int)wcslen(cli_argv[i]);
  moonbit_string_t result=moonbit_make_string_raw(n);
  memcpy(result,cli_argv[i],(size_t)n*sizeof(uint16_t));
  if(i==cli_argc-1) { LocalFree(cli_argv); cli_argv=NULL; }
  return result;
#else
  (void)i; return moonbit_make_string(0,0);
#endif
}

static int test_put(const char *name,const char *data,int n,int append);

MOONBIT_FFI_EXPORT moonbit_bytes_t mbsd_read(moonbit_bytes_t name,int32_t cap) {
  problem[0]=0;
  unsigned char *buffer=NULL; size_t used=0,capacity=0;
  if(cap<0) { fail("negative read cap",EINVAL); return bytes(NULL,0); }
#ifdef _WIN32
  wchar_t *path=wide((char*)name); if(!path) return bytes(NULL,0);
  HANDLE f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
  free(path);
  if(f==INVALID_HANDLE_VALUE) { fail("open input",GetLastError()); return bytes(NULL,0); }
  LARGE_INTEGER size;
  if(GetFileType(f)!=FILE_TYPE_DISK || !GetFileSizeEx(f,&size)) fail("stat regular input",GetLastError());
  else if(fault!=8 && size.QuadPart>cap) limit_fail("input size",cap);
#else
  int f=open((char*)name,O_RDONLY|O_CLOEXEC|O_NONBLOCK);
  if(f<0) { fail("open input",errno); return bytes(NULL,0); }
  struct stat st;
  if(fstat(f,&st)<0) fail("stat input",errno);
  else if(!S_ISREG(st.st_mode)) fail("input must be a regular file",EINVAL);
  else if(fault!=8 && st.st_size>cap) limit_fail("input size",cap);
#endif
  if(!problem[0] && fault==3 && !test_put((char*)name,"BC",2,1)) fail("test growth",EIO);
  while(!problem[0]) {
    unsigned char chunk[4096];
    size_t room=(size_t)cap-used;
    size_t request=room<sizeof(chunk)?room+1:sizeof(chunk);
    size_t count;
#ifdef _WIN32
    DWORD got=0;
    if(!ReadFile(f,chunk,(DWORD)request,&got,NULL)) { fail("read input",GetLastError()); break; }
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
  if(fault==7) fail("injected close input",EIO);
  moonbit_bytes_t result=problem[0]?bytes(NULL,0):bytes(buffer,used);
  free(buffer); return result;
}

MOONBIT_FFI_EXPORT int32_t mbsd_output_check(moonbit_bytes_t a,moonbit_bytes_t b,moonbit_bytes_t out) {
  problem[0]=0;
#ifdef _WIN32
  wchar_t *p=wide((char*)out); if(!p) return 0;
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
  struct stat t,l;
  if(lstat((char*)out,&l)==0) {
    if(stat((char*)out,&t)==0) {
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
static HANDLE pair_parent(moonbit_bytes_t name,wchar_t full[32768],wchar_t **leaf) {
  wchar_t *p=wide((char*)name); if(!p) return INVALID_HANDLE_VALUE;
  DWORD n=GetFullPathNameW(p,32768,full,NULL); free(p);
  if(!n || n>=32768) { fail("resolve output pair",GetLastError()); return INVALID_HANDLE_VALUE; }
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
  int fd=open(parent,O_PATH|O_DIRECTORY|O_CLOEXEC); free(parent);
  if(fd<0) fail("open output pair parent",errno);
  return fd;
}
#endif
MOONBIT_FFI_EXPORT int32_t mbsd_pair_check(moonbit_bytes_t a,moonbit_bytes_t b) {
  problem[0]=0;
#ifdef _WIN32
  wchar_t full_a[32768],full_b[32768],*leaf_a=NULL,*leaf_b=NULL;
  HANDLE pa=pair_parent(a,full_a,&leaf_a),pb=pair_parent(b,full_b,&leaf_b);
  if(pa!=INVALID_HANDLE_VALUE && pb!=INVALID_HANDLE_VALUE) {
    BY_HANDLE_FILE_INFORMATION ia,ib;
    if(!GetFileInformationByHandle(pa,&ia) || !GetFileInformationByHandle(pb,&ib)) fail("output pair parent identity",GetLastError());
    else if(!(ia.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY) || !(ib.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)) fail("output pair parent is not a directory",ERROR_DIRECTORY);
    else if(ia.dwVolumeSerialNumber==ib.dwVolumeSerialNumber && ia.nFileIndexHigh==ib.nFileIndexHigh && ia.nFileIndexLow==ib.nFileIndexLow) {
      /* Conservatively reject case aliases even in case-sensitive Windows dirs. */
      int equal=CompareStringOrdinal(leaf_a,-1,leaf_b,-1,TRUE);
      if(!equal) fail("compare output pair names",GetLastError());
      else if(equal==CSTR_EQUAL) fail("patch and manifest have the same target",ERROR_ALREADY_EXISTS);
    }
  }
  if(pa!=INVALID_HANDLE_VALUE && !CloseHandle(pa)) fail("close output pair parent",GetLastError());
  if(pb!=INVALID_HANDLE_VALUE && !CloseHandle(pb)) fail("close output pair parent",GetLastError());
#else
  const char *leaf_a=NULL,*leaf_b=NULL;
  int pa=pair_parent(a,&leaf_a),pb=pair_parent(b,&leaf_b);
  if(pa>=0 && pb>=0) {
    struct stat ia,ib;
    if(fstat(pa,&ia)<0 || fstat(pb,&ib)<0) fail("output pair parent identity",errno);
    else if(ia.st_dev==ib.st_dev && ia.st_ino==ib.st_ino && !strcmp(leaf_a,leaf_b)) fail("patch and manifest have the same target",EEXIST);
  }
  if(pa>=0 && close(pa)<0) fail("close output pair parent",errno);
  if(pb>=0 && close(pb)<0) fail("close output pair parent",errno);
#endif
  return !problem[0];
}

#ifndef _WIN32
/* Set only by the private compatibility contract entrypoint. No product knobs. */
static int compat_force,compat_mutate,compat_selected,compat_retained;
static char compat_last[80];
static int same_inode(const struct stat *a,const struct stat *b) {
  return a->st_dev==b->st_dev && a->st_ino==b->st_ino;
}
static int private_entry(int dir,const char *name,int held,const struct stat *created) {
  struct stat named,current;
  return fstat(held,&current)==0 && S_ISDIR(current.st_mode) && current.st_uid==geteuid() &&
    (current.st_mode&07777)==0700 && same_inode(&current,created) &&
    fstatat(dir,name,&named,AT_SYMLINK_NOFOLLOW)==0 && same_inode(&named,created);
}
static int payload_entry(int dir,const struct stat *created) {
  struct stat named;
  return fstatat(dir,"payload",&named,AT_SYMLINK_NOFOLLOW)==0 && S_ISREG(named.st_mode) &&
    named.st_uid==geteuid() && (named.st_mode&07777)==0600 && same_inode(&named,created);
}
static void retained(const char *name) {
  compat_retained=1;
  size_t used=strlen(problem);
  snprintf(problem+used,sizeof(problem)-used,"; private temporary retained or renamed: %s (do not blindly delete)",name);
}
static int random_name(char name[80]) {
  unsigned char token[16];size_t at=0;
  while(at<sizeof(token)) {
    ssize_t n=getrandom(token+at,sizeof(token)-at,0);
    if(n<0 && errno==EINTR) continue;
    if(n<=0) { fail("temporary name entropy",n<0?errno:EIO);return 0; }
    at+=(size_t)n;
  }
  strcpy(name,".moonbsdiff-compat-");size_t prefix=strlen(name);
  static const char hex[]="0123456789abcdef";
  for(size_t i=0;i<sizeof(token);i++) { name[prefix+i*2]=hex[token[i]>>4];name[prefix+i*2+1]=hex[token[i]&15]; }
  name[prefix+sizeof(token)*2]=0;return 1;
}
static int compat_deliver(int dir,const char *leaf,moonbit_bytes_t data) {
  compat_selected++;
  struct stat parent,ds,ps;struct statfs fs;
  if(fstat(dir,&parent)<0 || fstatfs(dir,&fs)<0) { fail("compatibility parent metadata",errno);return 0; }
  /* Restrict permission assumptions to the locally validated ext filesystem.
   * Non-sticky writable parents and untrusted owners cannot protect mkdir/open. */
  if(fs.f_type!=EXT4_SUPER_MAGIC || !S_ISDIR(parent.st_mode) || parent.st_nlink==0 ||
     (parent.st_uid!=geteuid() && parent.st_uid!=0) ||
     ((parent.st_mode&0022) && !(parent.st_mode&S_ISVTX))) {
    fail("compatibility requires local ext permissions and protected output parent",EPERM);return 0;
  }
  int made=0,known_dir=0,payload=0,private_fd=-1,writer=-1,keeper=-1;
  char name[80]={0};
  for(unsigned attempt=0;attempt<128;attempt++) {
    if(compat_mutate==1 && !attempt) strcpy(name,".moonbsdiff-compat-collision");
    else if(!random_name(name)) return 0;
    if(mkdirat(dir,name,0700)==0) { made=1;break; }
    if(errno!=EEXIST) { fail("exclusive private directory creation",errno);return 0; }
  }
  if(!made) { fail("private directory name collisions exhausted",EEXIST);return 0; }
  strcpy(compat_last,name);
  if(fstatat(dir,name,&ds,AT_SYMLINK_NOFOLLOW)<0) fail("created private directory identity",errno);
  else {
    known_dir=1;
    if(!S_ISDIR(ds.st_mode) || ds.st_uid!=geteuid() || (ds.st_mode&07777)!=0700) fail("private directory permissions",EPERM);
  }
  if(!problem[0]) {
    private_fd=openat(dir,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(private_fd<0) fail("open private directory",errno);
    else if(!private_entry(dir,name,private_fd,&ds)) fail("private directory identity changed",ESTALE);
  }
  if(!problem[0]) {
    writer=openat(private_fd,"payload",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(writer<0) fail("exclusive private payload creation",errno);
    else if(fstat(writer,&ps)<0) fail("private payload identity",errno);
    else {
      payload=1;
      if(!S_ISREG(ps.st_mode) || ps.st_uid!=geteuid() || (ps.st_mode&07777)!=0600 || ps.st_nlink!=1) fail("private payload permissions",EPERM);
    }
  }
  if(!problem[0]) {
    keeper=openat(private_fd,"payload",O_PATH|O_NOFOLLOW|O_CLOEXEC);
    struct stat held;
    if(keeper<0 || fstat(keeper,&held)<0) fail("retain private payload identity",errno);
    else if(!same_inode(&held,&ps)) fail("private payload changed on open",ESTALE);
  }
  size_t at=0,n=Moonbit_array_length(data);
  while(!problem[0] && at<n) {
    size_t amount=n-at>32768?32768:n-at;
    if(fault==9 && amount>2) amount=2;
    if(fault==4 && at) { fail("injected write",EIO);break; }
    if(fault==4) amount=1;
    ssize_t done=fault==10?0:write(writer,data+at,amount);
    if(done<0 && errno==EINTR) continue;
    if(done<=0) { fail("write private payload",done<0?errno:EIO);break; }
    at+=(size_t)done;
  }
  if(writer>=0) { if(close(writer)<0) fail("close written private payload",errno);writer=-1; }
  if(fault==5) fail("injected close written private payload",EIO);
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
  if(!problem[0] && (!private_entry(dir,name,private_fd,&ds) || !payload_entry(private_fd,&ps))) fail("private temporary identity changed before delivery",ESTALE);
  if(!problem[0] && fault==6) fail("injected compatibility delivery",EACCES);
  int committed=0;
  if(!problem[0]) {
    if(linkat(private_fd,"payload",dir,leaf,0)<0) fail("compatibility deliver without replacement",errno);
    else committed=1;
  }
  /* These deletes rely on the protected parent and uid-private directory, NOT
   * on an atomic check/unlink illusion. Malicious same-uid/root control is out
   * of scope. Unexpected identity => retain, never follow/delete replacement. */
  int clean=1;
  if(compat_mutate==5 && committed) { fail("injected compatibility cleanup",EIO);clean=0; }
  if(private_fd>=0) {
    if(!private_entry(dir,name,private_fd,&ds)) clean=0;
    if(clean && payload) {
      if(!payload_entry(private_fd,&ps)) clean=0;
      else if(unlinkat(private_fd,"payload",0)<0) { fail("cleanup owned private payload",errno);clean=0; }
    }
  } else if(payload) clean=0;
  if(clean && made && known_dir) {
    struct stat named;
    if(fstatat(dir,name,&named,AT_SYMLINK_NOFOLLOW)<0 || !same_inode(&named,&ds)) clean=0;
    else if(unlinkat(dir,name,AT_REMOVEDIR)<0) { fail("cleanup owned private directory",errno);clean=0; }
  } else if(!known_dir) clean=0;
  if(!clean) { fail("private cleanup ownership uncertain",ESTALE);retained(name); }
  if(keeper>=0 && close(keeper)<0) fail("close private identity reference",errno);
  if(private_fd>=0 && close(private_fd)<0) fail("close private directory",errno);
  if(committed && problem[0]) {
    char original[256];memcpy(original,problem,sizeof(original));
    snprintf(problem,sizeof(problem),"output already delivered; %.225s",original);
  }
  return !problem[0];
}
static int anonymous_unavailable(int error) {
  return error==EOPNOTSUPP || error==EINVAL || error==EISDIR || error==ENOSYS || error==ENOENT;
}
#endif

/* Never removes final caller paths. Primary cleanup uses held identities;
 * compatibility cleanup uses only the protected private namespace above. */
MOONBIT_FFI_EXPORT int32_t mbsd_deliver(moonbit_bytes_t name,moonbit_bytes_t data) {
  problem[0]=0; size_t n=Moonbit_array_length(data),at=0;
#ifdef _WIN32
  wchar_t *relative=wide((char*)name); if(!relative) return 0;
  wchar_t full[32768],temp[32768];
  DWORD length=GetFullPathNameW(relative,32768,full,NULL); free(relative);
  if(!length || length>=32768) { fail("resolve output",GetLastError()); return 0; }
  wchar_t *slash=wcsrchr(full,L'\\');
  if(!slash || slash-full>32000) { fail("output parent",ERROR_INVALID_NAME); return 0; }
  size_t parent=(size_t)(slash-full)+1;
  HANDLE writer=INVALID_HANDLE_VALUE,keeper=INVALID_HANDLE_VALUE;
  for(unsigned attempt=0;attempt<128;attempt++) {
    memcpy(temp,full,parent*sizeof(wchar_t));
    if(fault==1 && attempt==0) wcscpy(temp+parent,L".moonbsdiff-collision.tmp");
    else swprintf(temp+parent,32768-parent,L".moonbsdiff-%lu-%u.tmp",(unsigned long)GetCurrentProcessId(),++sequence);
    writer=CreateFileW(temp,GENERIC_WRITE|DELETE|FILE_READ_ATTRIBUTES,FILE_SHARE_READ,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if(writer!=INVALID_HANDLE_VALUE) break;
    DWORD e=GetLastError(); if(e!=ERROR_FILE_EXISTS && e!=ERROR_ALREADY_EXISTS) { fail("exclusive temporary creation",e); return 0; }
  }
  if(writer==INVALID_HANDLE_VALUE) { fail("temporary name collisions exhausted",ERROR_FILE_EXISTS); return 0; }
  if(!DuplicateHandle(GetCurrentProcess(),writer,GetCurrentProcess(),&keeper,DELETE|FILE_READ_ATTRIBUTES, FALSE,0)) fail("retain temporary identity",GetLastError());
  while(!problem[0] && at<n) {
    DWORD amount=(DWORD)(n-at>32768?32768:n-at),done=0;
    if(fault==9 && amount>2) amount=2;
    if(fault==4 && at) { fail("injected write",ERROR_WRITE_FAULT); break; }
    if(fault==4) amount=1;
    if(!WriteFile(writer,data+at,amount,&done,NULL) || !done) { fail("write temporary",GetLastError()); break; }
    at+=done;
  }
  if(keeper==INVALID_HANDLE_VALUE) { FILE_DISPOSITION_INFO del={TRUE}; if(!SetFileInformationByHandle(writer,FileDispositionInfo,&del,sizeof(del))) fail("cleanup temporary",GetLastError()); }
  if(!CloseHandle(writer)) fail("close written temporary",GetLastError());
  if(fault==5) fail("injected close written temporary",ERROR_WRITE_FAULT);
  if(!problem[0] && fault==2 && !test_put((char*)name,"other",5,0)) fail("test target creation",EIO);
  if(!problem[0] && fault==6) fail("injected delivery",ERROR_ACCESS_DENIED);
  if(!problem[0]) {
    size_t size=sizeof(FILE_RENAME_INFO)+((size_t)length+1)*sizeof(wchar_t);
    FILE_RENAME_INFO *rename=calloc(1,size);
    if(!rename) fail("rename allocation",ERROR_NOT_ENOUGH_MEMORY);
    else {
      rename->ReplaceIfExists=FALSE; rename->RootDirectory=NULL; rename->FileNameLength=length*sizeof(wchar_t);
      memcpy(rename->FileName,full,length*sizeof(wchar_t));
      if(!SetFileInformationByHandle(keeper,FileRenameInfo,rename,(DWORD)size)) fail("deliver without replacement",GetLastError());
      free(rename);
    }
  }
  if(keeper!=INVALID_HANDLE_VALUE) {
    if(problem[0]) { FILE_DISPOSITION_INFO del={TRUE}; if(!SetFileInformationByHandle(keeper,FileDispositionInfo,&del,sizeof(del))) fail("cleanup temporary",GetLastError()); }
    if(!CloseHandle(keeper)) fail("close temporary identity",GetLastError());
  }
#else
  const char *path=(char*)name,*slash=strrchr(path,'/'),*leaf=slash?slash+1:path;
  size_t parent_len=slash?(size_t)(slash-path):1;
  char *parent=malloc(parent_len+2);
  if(!parent) { fail("parent allocation",ENOMEM); return 0; }
  if(slash) { if(!parent_len) strcpy(parent,"/"); else { memcpy(parent,path,parent_len); parent[parent_len]=0; } } else strcpy(parent,".");
  if(!*leaf || !strcmp(leaf,".") || !strcmp(leaf,"..")) { free(parent); fail("invalid output name",EINVAL); return 0; }
  int dir=open(parent,O_RDONLY|O_DIRECTORY|O_CLOEXEC); free(parent);
  if(dir<0) { fail("open output directory",errno); return 0; }
  /* O_TMPFILE creates a fresh unnamed inode. O_EXCL must not be used here:
   * Linux defines O_TMPFILE|O_EXCL to forbid its later linking. */
  int writer,keeper=-1;
  if(compat_force==1 || compat_force==2) { writer=-1;errno=compat_force==1?EOPNOTSUPP:EACCES; }
  else writer=openat(dir,".",O_TMPFILE|O_RDWR|O_CLOEXEC,0600);
  if(writer<0) {
    int error=errno;
    if(anonymous_unavailable(error)) compat_deliver(dir,leaf,data);
    else fail("anonymous temporary creation",error);
    if(close(dir)<0) fail("close output directory",errno);
    return !problem[0];
  }
  char reference[80]; snprintf(reference,sizeof(reference),"/proc/self/fd/%d",writer);
  if(compat_force==3 || compat_force==4) { keeper=-1;errno=ENOENT; }
  else keeper=open(reference,O_PATH|O_CLOEXEC);
  if(keeper<0) {
    int error=errno;
    int closed=close(writer)==0,close_error=closed?0:errno;
    if(compat_force==4) { closed=0;close_error=EIO; }
    if(!closed) fail("close anonymous temporary before compatibility",close_error);
    else if(error==ENOENT || error==ENOTDIR) compat_deliver(dir,leaf,data);
    else fail("retain temporary identity",error);
    if(close(dir)<0) fail("close output directory",errno);
    return !problem[0];
  }
  while(!problem[0] && at<n) {
    size_t amount=n-at>32768?32768:n-at;
    if(fault==9 && amount>2) amount=2;
    if(fault==4 && at) { fail("injected write",EIO); break; }
    if(fault==4) amount=1;
    ssize_t done=write(writer,data+at,amount);
    if(done<0) { if(errno==EINTR) continue; fail("write temporary",errno); break; }
    if(!done) { fail("write made no progress",EIO); break; } at+=(size_t)done;
  }
  if(close(writer)<0) fail("close written temporary",errno);
  if(fault==5) fail("injected close written temporary",EIO);
  if(!problem[0] && fault==2 && !test_put(path,"other",5,0)) fail("test target creation",EIO);
  if(!problem[0] && fault==6) fail("injected delivery",EACCES);
  if(!problem[0]) {
    snprintf(reference,sizeof(reference),"/proc/self/fd/%d",keeper);
    if(linkat(AT_FDCWD,reference,dir,leaf,AT_SYMLINK_FOLLOW)<0) fail("deliver without replacement",errno);
  }
  if(keeper>=0 && close(keeper)<0) fail("close temporary identity",errno);
  if(close(dir)<0) fail("close output directory",errno);
#endif
  return !problem[0];
}

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
#ifndef _WIN32
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
    if(file>=0) close(file);if(cd>=0) close(cd);
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
