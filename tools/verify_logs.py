"""Independent replay of packet, CM and RC framing from captured Android traffic."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
counts={}
for path in sorted((root/'miniEXViewTests/Fixtures').glob('*.txt')):
    packets=messages=rc=commands=0
    for number,line in enumerate(path.read_bytes().splitlines(),1):
        line=line.strip().lstrip(b"~")
        if not line: continue
        assert line.startswith(b'#') and line[4:5]==b' ' and line[9:10]==b' ' and line[12:13]==b' ',(path,number)
        def alpha(b):
            assert all(65<=x<=80 for x in b),(path,number,b)
            return int(''.join(format(x-65,'x') for x in b),16)
        length=alpha(line[10:12]);assert len(line)==13+length+4,(path,number,len(line),length)
        assert sum(line[1:-4])&65535==alpha(line[-4:]),(path,number,'checksum')
        packets+=1
        body=line[13:-4];start=0
        while True:
            pos=body.find(b'*a',start)
            if pos<0: break
            size=alpha(body[pos+2:pos+4]);end=pos+4+2*(size+5)
            assert end<=len(body),(path,number,'CM incomplete')
            raw=bytes(alpha(body[i:i+2]) for i in range(pos+4,end,2))
            messages+=1
            ident=raw[3]|raw[4]<<8
            if ident==0x0240 and raw[0]==5 and raw[1]==1:
                data=raw[5:];assert len(data)>=2
                rc+=1;offset=2
                required={0x40:1,0x41:2,0x42:2,0x43:2,0x44:0,0x45:0,0x46:3,0x49:6,0x4a:4,0x4b:1,0x4c:4,0x4d:4,0x4f:1}
                while offset<len(data):
                    n=data[offset];assert n>=1 and offset+n<len(data),(path,number,'RC incomplete',offset)
                    cmd=data[offset+1];payload=data[offset+2:offset+n+1]
                    assert cmd not in required or len(payload)==required[cmd],(path,number,'RC length',cmd)
                    assert cmd!=0x48 or len(payload)>=3,(path,number,'RC text')
                    commands+=1;offset+=n+1
            start=end
    counts[path.name]=(packets,messages,rc,commands)
    print(f'{path.name}: packets={packets} CM={messages} RC={rc} commands={commands}')
assert len(counts)==6 and all(p>0 and m>0 for p,m,_,_ in counts.values())
assert all(counts[f'RC from miniEX {size}.txt'][2]>0 for size in ('short','long'))
print('All 6 recordings passed framing and checksum verification.')
