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

/* Never removes a path supplied by the caller. Temporary cleanup uses a held
 * Windows file handle or closes an anonymous Linux inode, never unlink(path). */
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
  int writer=openat(dir,".",O_TMPFILE|O_RDWR|O_CLOEXEC,0600),keeper=-1;
  if(writer<0) { fail("anonymous temporary creation (requires O_TMPFILE filesystem)",errno); close(dir); return 0; }
  char reference[80]; snprintf(reference,sizeof(reference),"/proc/self/fd/%d",writer);
  keeper=open(reference,O_PATH|O_CLOEXEC);
  if(keeper<0) fail("retain temporary identity",errno);
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
