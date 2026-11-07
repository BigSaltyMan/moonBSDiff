"""Independent slow specification: Python suffix ordering and exhaustive local scores."""
import argparse,bisect,json,pathlib,re
ROOT=pathlib.Path(__file__).resolve().parents[1]

def plan(old,new):
    # Python-owned small-input slices are used only in this independent test tool.
    positions=sorted(range(len(old)+1),key=lambda p:old[p:])
    keys=[old[p:] for p in positions]
    def search(at):
        k=bisect.bisect_left(keys,new[at:])
        candidates=positions[max(0,k-1):min(len(positions),k+1)]
        best=(-1,0)
        for p in candidates:
            n=0
            while p+n<len(old) and at+n<len(new) and old[p+n]==new[at+n]:n+=1
            if n>=best[0]:best=(n,p)
        return best[1],best[0]
    scan=length=pos=last=lastpos=offset=0
    result=[];overlaps=0
    while scan<len(new):
        score=0;scan+=length;scored=scan
        while scan<len(new):
            pos,length=search(scan)
            while scored<scan+length:
                score+=int(0<=scored+offset<len(old) and old[scored+offset]==new[scored]);scored+=1
            if (length==score and length) or length>score+8:break
            score-=int(0<=scan+offset<len(old) and old[scan+offset]==new[scan]);scan+=1
        if length!=score or scan==len(new):
            front=max(range(min(scan-last,len(old)-lastpos)+1),key=lambda n:2*sum(old[lastpos+i]==new[last+i] for i in range(n))-n)
            back=0 if scan==len(new) else max(range(min(scan-last,pos)+1),key=lambda n:2*sum(old[pos-i]==new[scan-i] for i in range(1,n+1))-n)
            overlap=last+front-(scan-back)
            if overlap>0:
                overlaps+=1
                cut=max(range(overlap+1),key=lambda n:sum(new[last+front-overlap+i]==old[lastpos+front-overlap+i] for i in range(n))+sum(new[last+front-overlap+i]==old[pos-back+i] for i in range(n,overlap)))
                front-=overlap-cut;back-=cut
            result.append([last,lastpos,front,scan-back-last-front,pos-back-(lastpos+front)])
            last=scan-back;lastpos=pos-back;offset=pos-scan
    return result,overlaps

def verify(generate=False):
    vectors=json.loads((ROOT/'testdata/matching/segments.json').read_text())
    source=['// Generated from testdata/matching/segments.json; checked independently by Python.']
    for i,row in enumerate(vectors):
        result,overlaps=plan(row['old'].encode(),row['new'].encode())
        assert result==row['segments'],row['id']
        if row['id']=='overlap':assert overlaps==1
        if row['id']=='block-move':assert sum(s[2] for s in result)==64 and any(s[4]<0 for s in result)
        expected=', '.join('('+','.join(str(v)+('L' if j==4 else '') for j,v in enumerate(s))+')' for s in result)
        source+=['','///|',f'test "matching-compact-vector-{row["id"]}" {{',f'  let old = b"{row["old"]}"',f'  let new = b"{row["new"]}"','  let sa = suffix_test_build(old)','  let segments = matching_test_plan(old,new,sa)','  matching_check_plan(old,new,segments)',f'  let expected : Array[(Int32,Int32,Int32,Int32,Int64)] = [{expected}]','  assert_eq(segments.length(),expected.length())','  for i in 0..<segments.length() {','    let s = segments[i]','    assert_eq((s.new_start,s.old_start,s.diff_length,s.extra_length,s.seek),expected[i])','  }','}']
    path=ROOT/'matching_vectors_wbtest.mbt'
    if generate:path.write_text('\n'.join(source)+'\n',encoding='utf8',newline='\n')
    # Formatting is allowed; token comparison retains literals while permitting whitespace/trailing commas.
    tokens = lambda text: re.findall(r'"(?:\\.|[^"\\])*"|[A-Za-z_]\w*|\d+|[^\s,]', text)
    assert tokens(path.read_text()) == tokens('\n'.join(source)+'\n')
    print('3 complete segment vectors verified; one actual overlap and 64-byte block reuse')
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--generate',action='store_true');args=parser.parse_args();verify(args.generate)
