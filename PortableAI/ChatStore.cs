using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

public sealed class PortableChatStore : IDisposable {
    private readonly string root, token, origin, imageExe, imageModel, imageRoot, appRoot, imageBackend, imageVram, imageName;
    private readonly int port, imagePort, imageWidth, imageSteps;
    private TcpListener listener;
    private Thread acceptThread;
    private volatile bool stopped;
    private readonly object gate = new object();
    private readonly object imageGate = new object();
    private readonly object imageGenerationGate = new object();
    private Process activeImage;
    private readonly Dictionary<string,string> paths = new Dictionary<string,string>(StringComparer.Ordinal);
    private readonly Dictionary<string,Dictionary<string,object>> summaries = new Dictionary<string,Dictionary<string,object>>(StringComparer.Ordinal);
    private readonly HashSet<string> legacyIds = new HashSet<string>(StringComparer.Ordinal);
    private int unreadable;
    private const int MaxBytes = 48 * 1024 * 1024;
    private static readonly Encoding Utf8 = new UTF8Encoding(false);
    public PortableChatStore(string folder, string secret, int listenPort, string allowedOrigin, string generatorExe, string generatorModel, string generatedFolder, int generatorPort, string generatorBackend, string generatorVram, int generatorWidth, int generatorSteps, string generatorName) {
        root = Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar);
        token = secret; port = listenPort; origin = allowedOrigin;
        imageExe = Path.GetFullPath(generatorExe); imageModel = Path.GetFullPath(generatorModel);
        imageRoot = Path.GetFullPath(generatedFolder).TrimEnd(Path.DirectorySeparatorChar);
        imagePort=generatorPort; imageBackend=generatorBackend; imageVram=generatorVram; imageWidth=generatorWidth; imageSteps=generatorSteps; imageName=generatorName;
        appRoot = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(imageExe), ".."));
        Directory.CreateDirectory(root);
        Directory.CreateDirectory(imageRoot);
        LoadIndex();
    }
    private static JavaScriptSerializer Json() { return new JavaScriptSerializer { MaxJsonLength = MaxBytes, RecursionLimit = 100 }; }
    private static string Str(Dictionary<string,object> d, string key, string fallback = "") { object v; return d.TryGetValue(key,out v) && v != null ? Convert.ToString(v,CultureInfo.InvariantCulture) : fallback; }
    private static int Num(Dictionary<string,object> d, string key) { int n; return Int32.TryParse(Str(d,key),out n) ? n : 0; }
    private static IEnumerable<object> Items(object value) { var list = value as IEnumerable; if(list == null || value is string || value is IDictionary) return new object[0]; return list.Cast<object>(); }
    private static DateTimeOffset Time(string value, DateTimeOffset fallback) { DateTimeOffset parsed; return DateTimeOffset.TryParse(value,CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind,out parsed) ? parsed : fallback; }
    private static string Iso(DateTimeOffset time) { return time.ToString("o",CultureInfo.InvariantCulture); }
    private string Inside(string path) {
        string full = Path.GetFullPath(path);
        if(!full.StartsWith(root + Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("存档路径无效。");
        string current = full;
        while(current.Length > root.Length) {
            if((Directory.Exists(current) || File.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("存档目录不能使用链接路径。");
            current = Path.GetDirectoryName(current);
        }
        if((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("存档根目录不能使用链接路径。");
        return full;
    }
    private static bool ValidId(string value) { Guid id; return Guid.TryParseExact(value,"D",out id) && value == id.ToString("D"); }
    private Dictionary<string,object> ReadChat(string path) { return Json().DeserializeObject(File.ReadAllText(Inside(path),Utf8)) as Dictionary<string,object>; }
    private void AddIndex(Dictionary<string,object> chat, string path) {
        string id = Str(chat,"id");
        if(!ValidId(id)) throw new InvalidDataException("存档中的对话编号无效。");
        paths[id] = path;
        object m; int count = chat.TryGetValue("messages",out m) ? Items(m).Count() : 0;
        summaries[id] = new Dictionary<string,object> {
            {"id",id},{"title",Str(chat,"title")},{"createdAt",Str(chat,"createdAt")},{"updatedAt",Str(chat,"updatedAt")},
            {"date",Time(Str(chat,"createdAt"),DateTimeOffset.Now).ToLocalTime().ToString("yyyy-MM-dd")},{"messageCount",count},{"revision",Num(chat,"revision")}
        };
        string legacy = Str(chat,"legacyId"); if(legacy.Length > 0) legacyIds.Add(legacy);
    }
    private void LoadIndex() {
        foreach(string day in Directory.GetDirectories(root)) {
            DateTime date;
            if(!DateTime.TryParseExact(Path.GetFileName(day),"yyyy-MM-dd",CultureInfo.InvariantCulture,DateTimeStyles.None,out date)) continue;
            if((File.GetAttributes(day) & FileAttributes.ReparsePoint) != 0) continue;
            foreach(string folder in Directory.GetDirectories(day)) {
                if(!ValidId(Path.GetFileName(folder)) || (File.GetAttributes(folder) & FileAttributes.ReparsePoint) != 0) continue;
                string path=Path.Combine(folder,"聊天记录.json");
                if(!File.Exists(path)) continue;
                try { var chat=ReadChat(path); if(chat == null || Str(chat,"id") != Path.GetFileName(folder)) throw new InvalidDataException(); AddIndex(chat,path); } catch { unreadable++; }
            }
        }
    }
    public void Start() {
        listener=new TcpListener(IPAddress.Loopback,port);
        listener.Start();
        acceptThread=new Thread(Accept); acceptThread.IsBackground=true; acceptThread.Start();
    }
    private void Accept() {
        while(!stopped) {
            try { var client=listener.AcceptTcpClient(); ThreadPool.QueueUserWorkItem(delegate { Handle(client); }); }
            catch { if(stopped) return; }
        }
    }
    private static string Line(Stream stream,int max) {
        var bytes=new List<byte>();
        while(true) { int n=stream.ReadByte(); if(n<0) throw new EndOfStreamException(); if(n==10) break; if(n!=13) bytes.Add((byte)n); if(bytes.Count>max) throw new InvalidDataException("请求头过长。"); }
        return Encoding.ASCII.GetString(bytes.ToArray());
    }
    private static bool Equal(string a,string b) { if(a==null || b==null || a.Length!=b.Length) return false; int diff=0; for(int i=0;i<a.Length;i++) diff|=a[i]^b[i]; return diff==0; }
    private void Reply(Stream stream,int status,object data,bool cors) {
        byte[] body=data==null ? new byte[0] : Utf8.GetBytes(Json().Serialize(data));
        string reason=status==200?"OK":status==204?"No Content":status==400?"Bad Request":status==403?"Forbidden":status==404?"Not Found":status==409?"Conflict":status==413?"Payload Too Large":"Server Error";
        string header="HTTP/1.1 "+status+" "+reason+"\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\nContent-Length: "+body.Length+"\r\n";
        if(cors) header+="Access-Control-Allow-Origin: "+origin+"\r\nVary: Origin\r\nAccess-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\nAccess-Control-Max-Age: 600\r\n";
        byte[] head=Encoding.ASCII.GetBytes(header+"\r\n"); stream.Write(head,0,head.Length); stream.Write(body,0,body.Length); stream.Flush();
    }
    private void Handle(TcpClient client) {
        using(client) {
            client.ReceiveTimeout=30000; client.SendTimeout=30000;
            using(NetworkStream stream=client.GetStream()) {
                bool cors=false;
                try {
                    string[] request=Line(stream,8192).Split(' ');
                    if(request.Length!=3) throw new InvalidDataException("请求格式无效。");
                    var headers=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase); int headerSize=0;
                    while(true) { string line=Line(stream,16384); if(line.Length==0) break; headerSize+=line.Length; if(headerSize>32768) throw new InvalidDataException("Headers too large."); int colon=line.IndexOf(':'); if(colon<1) throw new InvalidDataException(); string key=line.Substring(0,colon).Trim(); if(headers.ContainsKey(key)) throw new InvalidDataException("Duplicate header."); headers[key]=line.Substring(colon+1).Trim(); }
                    string host, receivedOrigin, auth;
                    if(!headers.TryGetValue("Host",out host) || host!="127.0.0.1:"+port) { Reply(stream,403,new {ok=false,error="主机地址无效。"},false); return; }
                    bool hasOrigin=headers.TryGetValue("Origin",out receivedOrigin);
                    if(hasOrigin && receivedOrigin!=origin) { Reply(stream,403,new {ok=false,error="页面来源不被允许。"},false); return; }
                    cors=hasOrigin;
                    if(request[0]=="OPTIONS") { Reply(stream,204,null,cors); return; }
                    if(!headers.TryGetValue("Authorization",out auth) || !Equal(auth,"Bearer "+token)) { Reply(stream,403,new {ok=false,error="本地会话已失效，请关闭后从 U 盘重新启动。"},cors); return; }
                    if(headers.ContainsKey("Transfer-Encoding")) throw new InvalidDataException("不支持分块请求。");
                    int length=0; string lengthText;
                    if(headers.TryGetValue("Content-Length",out lengthText) && (!Int32.TryParse(lengthText,out length) || length<0)) throw new InvalidDataException("请求长度无效。");
                    if(length>MaxBytes) { Reply(stream,413,new {ok=false,error="数据超过 32 MB，原聊天没有被修改。"},cors); return; }
                    byte[] bytes=new byte[length]; int offset=0;
                    while(offset<length) { int n=stream.Read(bytes,offset,length-offset); if(n<=0) throw new EndOfStreamException(); offset+=n; }
                    string url=request[1].Split('?')[0];
                    object result;
                    if(request[0]=="POST" && url=="/api/images/cancel") {
                        CancelImage(); Reply(stream,200,new {ok=true},cors); return;
                    }
                    if(request[0]=="POST" && url=="/api/images") {
                        var imageInput=Json().DeserializeObject(Utf8.GetString(bytes)) as Dictionary<string,object>;
                        if(imageInput==null) throw new InvalidDataException("生图请求无效。");
                        result=GenerateImage(imageInput); Reply(stream,200,result,cors); return;
                    }
                    lock(gate) {
                        if(request[0]=="GET" && (url=="/api/state" || url=="/api/health")) {
                            result=new {ok=true,storageRoot=root,imageRoot=imageRoot,imageReady=File.Exists(imageExe)&&File.Exists(imageModel),imageModel=imageName,imageSize=imageWidth,imageSteps=imageSteps,today=DateTime.Now.ToString("yyyy-MM-dd"),unreadableChats=unreadable,chats=summaries.Values.OrderByDescending(x=>Str(x,"updatedAt")).ToArray()};
                        } else if(request[0]=="GET" && url.StartsWith("/api/chats/",StringComparison.Ordinal)) {
                            string id=url.Substring(11),path;
                            if(!ValidId(id) || !paths.TryGetValue(id,out path)) { Reply(stream,404,new {ok=false,error="没有找到这段聊天。"},cors); return; }
                            result=new {ok=true,chat=ReadChat(path),path=path};
                        } else if(request[0]=="POST" && url=="/api/chats") {
                            var input=Json().DeserializeObject(Utf8.GetString(bytes)) as Dictionary<string,object>;
                            if(input==null) throw new InvalidDataException("聊天数据无效。");
                            result=SaveChat(input,false);
                        } else if(request[0]=="DELETE" && url.StartsWith("/api/chats/",StringComparison.Ordinal)) {
                            string id=url.Substring(11),path;
                            if(!ValidId(id) || !paths.TryGetValue(id,out path)) { Reply(stream,404,new {ok=false,error="没有找到这段聊天。"},cors); return; }
                            string folder=Inside(Path.GetDirectoryName(path));
                            if(Path.GetFileName(folder)!=id || !Directory.Exists(folder)) throw new InvalidDataException("聊天存档目录无效，已停止删除。");
                            Directory.Delete(folder,true); paths.Remove(id); summaries.Remove(id);
                            result=new {ok=true,id=id};
                        } else if(request[0]=="POST" && url=="/api/import") {
                            var input=Json().DeserializeObject(Utf8.GetString(bytes)) as Dictionary<string,object>;
                            if(input==null) throw new InvalidDataException("导入数据无效。");
                            result=Import(input);
                        } else { Reply(stream,404,new {ok=false,error="未知接口。"},cors); return; }
                    }
                    Reply(stream,200,result,cors);
                } catch(RevisionConflict) { try { Reply(stream,409,new {ok=false,error="这段聊天已在另一个窗口更新，请刷新后继续。"},cors); } catch {} }
                catch(InvalidDataException e) { try { Reply(stream,400,new {ok=false,error=e.Message},cors); } catch {} }
                catch(ArgumentException) { try { Reply(stream,400,new {ok=false,error="JSON 或请求数据无效。"},cors); } catch {} }
                catch(Exception) { try { Reply(stream,500,new {ok=false,error="无法写入 U 盘，请确认 U 盘仍连接并且有剩余空间。"},cors); } catch {} }
            }
        }
    }
    private sealed class RevisionConflict:Exception {}
    private object SaveChat(Dictionary<string,object> input,bool importing) {
        string id=Str(input,"id");
        if(!ValidId(id)) throw new InvalidDataException("对话编号格式无效。");
        string path;
        Dictionary<string,object> old=null;
        if(paths.TryGetValue(id,out path)) old=ReadChat(path);
        if(old!=null && !importing && Num(old,"revision")!=Num(input,"revision")) throw new RevisionConflict();
        if(old==null && !importing && Num(input,"revision")!=0) throw new RevisionConflict();
        var now=DateTimeOffset.Now;
        var created=old!=null ? Time(Str(old,"createdAt"),now) : Time(Str(input,"createdAt"),now);
        if(created.Year<1970 || created.Year>now.Year+1) created=now;
        string title=Str(input,"title").Trim(); if(title.Length==0) title="新对话"; if(title.Length>100) title=title.Substring(0,100);
        object messageValue; var messages=new List<Dictionary<string,object>>();
        if(!input.TryGetValue("messages",out messageValue) || !(messageValue is IEnumerable) || messageValue is string || messageValue is IDictionary) throw new InvalidDataException("消息列表格式无效。");
        foreach(object item in Items(messageValue)) {
            var message=item as Dictionary<string,object>; if(message==null) throw new InvalidDataException("消息格式无效。");
            string role=Str(message,"role"); if(role!="user" && role!="assistant" && role!="system") throw new InvalidDataException("消息角色不受支持。");
            string content=Str(message,"content"); if(content.Length>4*1024*1024) throw new InvalidDataException("单条消息文字过大。");
            var normalized=new Dictionary<string,object>{{"id",Str(message,"id",Guid.NewGuid().ToString("D"))},{"role",role},{"content",content},{"createdAt",Iso(Time(Str(message,"createdAt"),created))}};
            string editedAt=Str(message,"editedAt"); if(editedAt.Length>0) normalized["editedAt"]=Iso(Time(editedAt,now));
            string model=Str(message,"model"); if(model.Length>0) normalized["model"]=model;
            string kind=Str(message,"kind"); if(kind=="chat" || kind=="generated-image") normalized["kind"]=kind;
            object imageValue;
            if(message.TryGetValue("images",out imageValue)) {
                var safeImages=new List<Dictionary<string,object>>();
                foreach(object raw in Items(imageValue)) {
                    var image=raw as Dictionary<string,object>; if(image==null) throw new InvalidDataException("图片附件格式无效。");
                    string dataUrl=Str(image,"dataUrl"), type=Str(image,"type"), name=Str(image,"name","图片");
                    if(dataUrl.Length>12*1024*1024 || !(dataUrl.StartsWith("data:image/jpeg;base64,",StringComparison.Ordinal) || dataUrl.StartsWith("data:image/png;base64,",StringComparison.Ordinal) || dataUrl.StartsWith("data:image/webp;base64,",StringComparison.Ordinal))) throw new InvalidDataException("图片附件无效或过大。");
                    if(name.Length>120) name=name.Substring(0,120);
                    var safe=new Dictionary<string,object>{{"name",name},{"type",type},{"dataUrl",dataUrl}};
                    string savedPath=Str(image,"path"); if(savedPath.Length>0 && savedPath.StartsWith(imageRoot+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)) safe["path"]=savedPath;
                    safeImages.Add(safe); if(safeImages.Count>=2) break;
                }
                if(safeImages.Count>0) normalized["images"]=safeImages;
            }
            object metaValue;
            var meta=message.TryGetValue("meta",out metaValue)?metaValue as Dictionary<string,object>:null;
            if(meta!=null) {
                var safeMeta=new Dictionary<string,object>(); object value;
                if(meta.TryGetValue("seed",out value)) safeMeta["seed"]=value;
                if(meta.TryGetValue("elapsedSeconds",out value)) safeMeta["elapsedSeconds"]=value;
                if(meta.TryGetValue("width",out value)) safeMeta["width"]=value;
                if(meta.TryGetValue("height",out value)) safeMeta["height"]=value;
                if(meta.TryGetValue("steps",out value)) safeMeta["steps"]=value;
                string imageModelName=Str(meta,"model"); if(imageModelName.Length>0) safeMeta["model"]=imageModelName.Length>100?imageModelName.Substring(0,100):imageModelName;
                string englishPrompt=Str(meta,"englishPrompt"); if(englishPrompt.Length>0) safeMeta["englishPrompt"]=englishPrompt.Length>2000?englishPrompt.Substring(0,2000):englishPrompt;
                if(safeMeta.Count>0) normalized["meta"]=safeMeta;
            }
            messages.Add(normalized);
            if(messages.Count>20000) throw new InvalidDataException("一段聊天中的消息过多。");
        }
        string legacy=old!=null ? Str(old,"legacyId") : Str(input,"legacyId");
        var chat=new Dictionary<string,object>{{"schemaVersion",2},{"id",id},{"title",title},{"createdAt",Iso(created)},{"updatedAt",importing?Iso(Time(Str(input,"updatedAt"),now)):Iso(now)},{"revision",old==null?1:Num(old,"revision")+1},{"messages",messages}};
        if(legacy.Length>0) chat["legacyId"]=legacy;
        string modelName=Str(input,"model"); if(modelName.Length>0) chat["model"]=modelName;
        if(path==null) {
            path=Inside(Path.Combine(root,created.ToLocalTime().ToString("yyyy-MM-dd"),id,"聊天记录.json"));
            if(File.Exists(path)) throw new InvalidDataException("同名存档已经存在；为防止覆盖，已停止保存。");
        }
        Directory.CreateDirectory(Inside(Path.GetDirectoryName(path)));
        AtomicWrite(path,Json().Serialize(chat));
        // JSON is authoritative; markdown can always be rebuilt from it.
        try { AtomicWrite(Path.Combine(Path.GetDirectoryName(path),"聊天记录.md"),Markdown(chat,messages)); } catch { /* JSON remains the authoritative recoverable record. */ }
        AddIndex(chat,path);
        return new {ok=true,chat=chat,path=path};
    }
    private static string Markdown(Dictionary<string,object> chat,List<Dictionary<string,object>> messages) {
        var text=new StringBuilder(); text.Append("# ").Append(Str(chat,"title").Replace("\r"," ").Replace("\n"," ")).Append("\r\n\r\n");
        text.Append("创建：").Append(Str(chat,"createdAt")).Append("\r\n更新：").Append(Str(chat,"updatedAt")).Append("\r\n\r\n");
        foreach(var message in messages) {
            string role=Str(message,"role"); text.Append("## ").Append(role=="user"?"我":role=="assistant"?"AI":"系统提示").Append("\r\n\r\n").Append(Str(message,"content")).Append("\r\n\r\n");
            object imageValue; if(message.TryGetValue("images",out imageValue)) foreach(object raw in Items(imageValue)) { var image=raw as Dictionary<string,object>; if(image!=null) { string saved=Str(image,"path"); text.Append("[图片：").Append(Str(image,"name","图片")); if(saved.Length>0) text.Append(" | ").Append(saved); text.Append("]\r\n\r\n"); } }
        }
        return text.ToString();
    }
    private void AtomicWrite(string path,string text) {
        path=Inside(path); byte[] bytes=Utf8.GetBytes(text);
        string temp=Inside(path+"."+Guid.NewGuid().ToString("N")+".tmp");
        try {
            using(var file=new FileStream(temp,FileMode.CreateNew,FileAccess.Write,FileShare.None,65536,FileOptions.WriteThrough)) { file.Write(bytes,0,bytes.Length); file.Flush(true); }
            if(File.Exists(path)) File.Replace(temp,path,null); else File.Move(temp,path);
        } finally { if(File.Exists(temp)) File.Delete(temp); }
    }
    private static string Arg(string value) {
        if(value==null) return "\"\"";
        var result=new StringBuilder("\""); int slashes=0;
        foreach(char c in value) {
            if(c=='\\') { slashes++; continue; }
            if(c=='"') { result.Append('\\',slashes*2+1).Append('"'); slashes=0; continue; }
            if(slashes>0) { result.Append('\\',slashes); slashes=0; }
            result.Append(c);
        }
        if(slashes>0) result.Append('\\',slashes*2);
        return result.Append('"').ToString();
    }
    private static int IntValue(Dictionary<string,object> input,string key,int fallback) { object value; int number; return input.TryGetValue(key,out value)&&Int32.TryParse(Convert.ToString(value,CultureInfo.InvariantCulture),out number)?number:fallback; }
    private static string Tail(string value,int count) { if(String.IsNullOrEmpty(value)) return ""; return value.Length<=count?value:value.Substring(value.Length-count); }
    private Dictionary<string,object> ImageRequest(string path,Dictionary<string,object> body,int timeoutMs) {
        var request=(HttpWebRequest)WebRequest.Create("http://127.0.0.1:"+imagePort+path); request.Proxy=null; request.Timeout=timeoutMs; request.ReadWriteTimeout=timeoutMs;
        if(body!=null) { byte[] bytes=Utf8.GetBytes(Json().Serialize(body)); request.Method="POST"; request.ContentType="application/json"; request.ContentLength=bytes.Length; using(var stream=request.GetRequestStream()) stream.Write(bytes,0,bytes.Length); }
        try {
            using(var response=(HttpWebResponse)request.GetResponse()) using(var reader=new StreamReader(response.GetResponseStream(),Utf8)) return Json().DeserializeObject(reader.ReadToEnd()) as Dictionary<string,object>;
        } catch(WebException error) {
            string detail=""; var response=error.Response as HttpWebResponse;
            if(response!=null) try { using(response) using(var reader=new StreamReader(response.GetResponseStream(),Utf8)) detail=reader.ReadToEnd(); } catch { }
            throw new InvalidDataException("生图服务没有完成请求"+(detail.Length>0?"："+Tail(detail,600):"。"));
        }
    }
    private bool ImageServerReady() {
        try { var data=ImageRequest("/v1/models",null,1800); object value; return data!=null&&data.TryGetValue("data",out value)&&Items(value).Any(); } catch { return false; }
    }
    private void EnsureImageServer() {
        if(!File.Exists(imageExe) || !File.Exists(imageModel)) throw new InvalidDataException("离线生图组件尚未安装完整。");
        Process process;
        lock(imageGate) {
            if(activeImage!=null&&activeImage.HasExited) { activeImage.Dispose(); activeImage=null; }
            if(activeImage==null) {
                var args=new List<string>{"-m",Arg(imageModel),"--listen-ip","127.0.0.1","--listen-port",imagePort.ToString(CultureInfo.InvariantCulture),"--max-pending-jobs","1","--completed-ttl-seconds","120","--threads",Math.Min(8,Environment.ProcessorCount).ToString(CultureInfo.InvariantCulture),"--backend",Arg(imageBackend)};
                if(imageVram.Length>0) { args.Add("--max-vram"); args.Add(Arg(imageVram)); }
                args.AddRange(new[]{"--offload-to-cpu","--flash-attn","on","--auto-fit","on","--log-level","error"});
                var info=new ProcessStartInfo(imageExe,String.Join(" ",args.ToArray())) {WorkingDirectory=Path.GetDirectoryName(imageExe),UseShellExecute=false,CreateNoWindow=true};
                string temp=Path.Combine(appRoot,"temp"),cache=Path.Combine(appRoot,"cache"); Directory.CreateDirectory(temp); Directory.CreateDirectory(cache);
                info.EnvironmentVariables["TEMP"]=temp; info.EnvironmentVariables["TMP"]=temp; info.EnvironmentVariables["LOCALAPPDATA"]=Path.Combine(appRoot,"profile-local"); info.EnvironmentVariables["APPDATA"]=Path.Combine(appRoot,"profile-roaming"); info.EnvironmentVariables["XDG_CACHE_HOME"]=cache;
                process=new Process(); process.StartInfo=info; if(!process.Start()) throw new InvalidDataException("无法启动离线生图服务。"); activeImage=process;
            } else process=activeImage;
        }
        var watch=Stopwatch.StartNew(); while(watch.Elapsed.TotalSeconds<120) { if(process.HasExited) throw new InvalidDataException("离线生图服务启动失败。"); if(ImageServerReady()) return; Thread.Sleep(350); }
        throw new InvalidDataException("离线生图模型加载超时，请重新启动浮光。");
    }
    public Process ImageProcess { get { lock(imageGate) return activeImage; } }
    private object GenerateImage(Dictionary<string,object> input) {
        lock(imageGenerationGate) {
            string prompt=Str(input,"prompt").Trim(); if(prompt.Length<2 || prompt.Length>2000) throw new InvalidDataException("画面描述需要 2 到 2000 个字符。");
            int width=imageWidth,height=imageWidth,steps=IntValue(input,"steps",imageSteps),seed=IntValue(input,"seed",-1); if(steps<1)steps=1;if(steps>4)steps=4;
            if(seed<0) { var randomBytes=new byte[4]; using(var random=RandomNumberGenerator.Create()) random.GetBytes(randomBytes); seed=BitConverter.ToInt32(randomBytes,0)&0x7fffffff; if(seed==0) seed=42; }
            EnsureImageServer(); var watch=Stopwatch.StartNew();
            var payload=new Dictionary<string,object>{{"prompt",prompt},{"negative_prompt","blurry, low quality, distorted, watermark, text"},{"width",width},{"height",height},{"steps",steps},{"cfg_scale",1.0},{"seed",seed},{"batch_size",1},{"sampler_name","euler_a"},{"scheduler","discrete"}};
            var result=ImageRequest("/sdapi/v1/txt2img",payload,15*60*1000); watch.Stop(); object imagesValue; var encoded=result!=null&&result.TryGetValue("images",out imagesValue)?Items(imagesValue).FirstOrDefault() as string:null;
            if(String.IsNullOrWhiteSpace(encoded)) throw new InvalidDataException("生图模型没有返回图片。"); int comma=encoded.IndexOf(','); if(encoded.StartsWith("data:",StringComparison.Ordinal)&&comma>=0) encoded=encoded.Substring(comma+1);
            byte[] imageBytes; try { imageBytes=Convert.FromBase64String(encoded); } catch { throw new InvalidDataException("生图模型返回的图片数据无效。"); }
            if(imageBytes.Length>16*1024*1024) throw new InvalidDataException("生成图片超过 16MB。");
            string dayFolder=Path.Combine(imageRoot,DateTime.Now.ToString("yyyy-MM-dd")); Directory.CreateDirectory(dayFolder); string fileName=DateTime.Now.ToString("HHmmss-fff")+"-"+Guid.NewGuid().ToString("N").Substring(0,6)+".png"; string outputPath=Path.Combine(dayFolder,fileName); File.WriteAllBytes(outputPath,imageBytes);
            return new {ok=true,fileName=fileName,path=outputPath,dataUrl="data:image/png;base64,"+encoded,seed=seed,elapsedSeconds=Math.Round(watch.Elapsed.TotalSeconds,1),model=imageName,width=width,height=height,steps=steps};
        }
    }
    private void CancelImage() {
        Process process=null; lock(imageGate) { process=activeImage; activeImage=null; }
        if(process!=null) { try { if(!process.HasExited) process.Kill(); } catch { } try { process.Dispose(); } catch { } }
    }
    private object Import(Dictionary<string,object> input) {
        object list; if(!input.TryGetValue("conversations",out list)) throw new InvalidDataException("缺少旧聊天数据。");
        var incoming=Items(list).Select(x=>x as Dictionary<string,object>).ToArray();
        if(incoming.Any(x=>x==null || !ValidId(Str(x,"id")) || Str(x,"legacyId").Length==0)) throw new InvalidDataException("旧聊天数据无效。");
        int skipped=incoming.Count(x=>legacyIds.Contains(Str(x,"legacyId")) || paths.ContainsKey(Str(x,"id")));
        if(skipped==incoming.Length) return new {ok=true,imported=0,skipped=skipped};
        // Back up the untouched source data before creating converted chats.
        string backupFolder=Inside(Path.Combine(root,"历史导入")); Directory.CreateDirectory(backupFolder);
        string backupPath=Path.Combine(backupFolder,DateTime.Now.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N").Substring(0,8)+".json");
        AtomicWrite(backupPath,Json().Serialize(input));
        int imported=0;
        foreach(var chat in incoming) { if(legacyIds.Contains(Str(chat,"legacyId")) || paths.ContainsKey(Str(chat,"id"))) continue; SaveChat(chat,true); imported++; }
        return new {ok=true,imported=imported,skipped=skipped};
    }
    public void Dispose() { stopped=true; CancelImage(); if(listener!=null) listener.Stop(); if(acceptThread!=null && acceptThread.IsAlive) acceptThread.Join(2000); }
}
