import re,json,sys,urllib.request,urllib.parse
def query(**p):
    q=[('appid','431960'),('section','readytouseitems')]+[(k,v) for k,vs in p.items() for v in (vs if isinstance(vs,list) else [vs])]
    url='https://steamcommunity.com/workshop/browse/?'+urllib.parse.urlencode(q)
    s=urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'}),timeout=20).read().decode('utf-8','ignore')
    m=re.search(r'<script type="application/json" id="valve-ssr-data"[^>]*>(.*?)</script>',s,re.S)
    root=json.loads(m.group(1)); qd=json.loads(root['renderContext']['queryData'])
    for qq in qd['queries']:
        d=qq['state'].get('data')
        if isinstance(d,dict) and 'results' in d: return qq['queryKey'],d
for args in [dict(searchtext='bonfire',browsesort='textsearch'), dict(browsesort='trend',days='7',**{'requiredtags[]':['Scene','Everyone']},p='2'), dict(browsesort='toprated',**{'requiredtags[]':'Video'})]:
    key,d=query(**args)
    print(args,'\n  queryKey:',json.dumps(key)[:200],'\n  total',d['total_count'],'pages',d['total_pages'],'page',d['current_page'],'n',len(d['results']))
    r=d['results'][0]; print('  ex:',r['publishedfileid'],r['title'][:40],int(r['file_size'])//1048576,'Mo',[t['tag'] for t in r['tags']][:6], 'vote' ,r.get('vote_data'), 'subs',r.get('subscriptions'))
print(sorted(r.keys()))
