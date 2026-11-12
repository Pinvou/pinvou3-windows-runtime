"""Publish immutable runtime assets, verifying the committed manifest first."""
import argparse,hashlib,json,re,subprocess,tempfile
from pathlib import Path

def digest(path):
    value=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):value.update(chunk)
    return value.hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--commit',default='HEAD')
    parser.add_argument('--payload-root',required=True,type=Path,help='Directory containing the materialized payload/ folder')
    parser.add_argument('--repo',default='Pinvou/pinvou3-windows-runtime')
    parser.add_argument('--check-only',action='store_true')
    args=parser.parse_args()
    root=Path(__file__).resolve().parent.parent
    def git(*arguments):return subprocess.check_output(['git','-C',str(root),*arguments])
    def gh(*arguments):return subprocess.check_output(['gh',*arguments],text=True,encoding='utf8')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',args.repo):raise ValueError('Invalid GitHub repository')
    commit=git('rev-parse','--verify',args.commit+'^{commit}').decode('ascii').strip()
    if not re.fullmatch('[a-f0-9]{40}',commit):raise ValueError('Expected an exact Git commit')
    raw=git('show',commit+':windows-runtime.manifest.json');manifest=json.loads(raw)
    if manifest['schemaVersion']!=2 or manifest['target']!='windows-x86_64' or not manifest['files']:raise ValueError('Unsupported runtime manifest')
    base=args.payload_root.resolve();assets=[];names=set()
    for entry in manifest['files']:
        relative=entry['path']
        if not re.fullmatch(r'payload/[A-Za-z0-9_./-]+',relative) or any(p in ('','.','..') for p in relative.split('/')):raise ValueError('Invalid payload path')
        file=(base/relative).resolve();file.relative_to(base)
        if file.name.lower() in names:raise ValueError('Duplicate Release asset basename')
        names.add(file.name.lower())
        if not 0<entry['bytes']<2**31 or not re.fullmatch('[a-f0-9]{64}',entry['sha256']):raise ValueError('Invalid payload identity')
        if file.stat().st_size!=entry['bytes'] or digest(file)!=entry['sha256']:raise ValueError('Payload size/SHA256 mismatch: '+relative)
        assets.append(file)
    tag='runtime-'+commit
    result={'commit':commit,'tag':tag,'manifest_sha256':hashlib.sha256(raw).hexdigest(),'verified_payloads':len(assets)}
    if args.check_only:
        print(json.dumps(result));return
    # Draft releases have no tag ref yet; inspect the release list as well.
    releases=json.loads(gh('api',f'repos/{args.repo}/releases','--paginate','--slurp'))
    if any(r['tag_name']==tag for page in releases for r in page):raise ValueError('Release already exists; never replace immutable assets')
    ref=subprocess.run(['gh','api',f'repos/{args.repo}/git/ref/tags/{tag}'],capture_output=True)
    if ref.returncode==0:raise ValueError('Tag already exists; review it before publishing')
    if b'HTTP 404' not in ref.stderr:raise RuntimeError('Unable to verify tag availability')
    with tempfile.TemporaryDirectory(prefix='pinvou-runtime-release-') as temporary:
        stage=Path(temporary);mf=stage/'windows-runtime.manifest.json';mf.write_bytes(raw);assets.append(mf)
        sums=stage/'SHA256SUMS';sums.write_text(''.join(digest(p)+'  '+p.name+'\n' for p in assets),encoding='ascii');assets.append(sums)
        notes=stage/'notes.txt';notes.write_text(f'Fixed Windows x64 runtime snapshot `{commit}`.\n\nAll payloads match the committed manifest. Consumers must pin this tag and verify SHA256. No Git LFS downloads are required.\n\nManifest SHA256: `{result["manifest_sha256"]}`.\n',encoding='utf8')
        gh('release','create',tag,'--repo',args.repo,'--target',commit,'--draft','--title','Windows x64 runtime '+commit[:12],'--notes-file',str(notes))
        subprocess.run(['gh','release','upload',tag,'--repo',args.repo,*map(str,assets)],check=True)
        release=next(r for r in json.loads(gh('api',f'repos/{args.repo}/releases')) if r['tag_name']==tag)
        if not release['draft'] or release['target_commitish']!=commit:raise ValueError('Unexpected draft identity')
        remote={a['name']:a for a in release['assets']}
        if set(remote)!={p.name for p in assets}:raise ValueError('Unexpected uploaded asset set')
        for file in assets:
            item=remote[file.name]
            if item['size']!=file.stat().st_size or item.get('digest')!='sha256:'+digest(file) or item['state']!='uploaded':raise ValueError('Uploaded asset digest mismatch')
        gh('api','--method','PATCH',f'repos/{args.repo}/releases/{release["id"]}','-F','draft=false','-f','make_latest=false')
        ref=json.loads(gh('api',f'repos/{args.repo}/git/ref/tags/{tag}'))
        if ref['object']['type']!='commit' or ref['object']['sha']!=commit:raise ValueError('Published tag differs from the intended commit')
        result['url']=release['html_url'];print(json.dumps(result))

if __name__=='__main__':main()
