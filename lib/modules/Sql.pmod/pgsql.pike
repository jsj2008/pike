/*
 * This is the PostgreSQL direct network module for Pike.
 *
 * TODO: support SSL connections
 */

//! This is an interface to the PostgreSQL database
//! server. This module is independent of external libraries.
//! Note that you @b{do not@} need to have a
//! PostgreSQL server running on your host to use this module: you can
//! connect to the database over a TCP/IP socket.
//! 
//! This module replaces the functionality of the older @[Sql.postgres]
//! and @[Postgres.postgres] modules.
//!
//! This module implements the PostgreSQL network protocol version 3.
//! Refer to the PostgreSQL documentation for further details.
//!
//! @seealso
//!  @[Sql.Sql], @[Sql.postgres]

#pike __REAL_VERSION__

//#define DEBUG  1
//#define DEBUGMORE  1

#ifdef DEBUG
#define PD(X ...)     werror(X)
#define UNBUFFEREDIO  1		    // Make all IO unbuffered
#else
#undef DEBUGMORE
#define PD(X ...)
#endif
//#define NO_LOCKING  1		    // This breaks the driver, do not enable,
				    // only for benchmarking mutex performance

#define FETCHLIMIT           1024   // Initial upper limit on the
				    // number of rows to fetch across the
				    // network at a time
				    // 0 for no chunking
				    // Needs to be >0 for interleaved
				    // portals
#define FETCHLIMITLONGRUN    1      // for long running background queries
#define STREAMEXECUTES	     1	    // streams executes if defined
#define MINPREPARELENGTH     64	    // statements shorter than this will not
				    // be cached
#define PGSQL_DEFAULT_PORT   5432
#define PGSQL_DEFAULT_HOST   "localhost"
#define PREPSTMTPREFIX	     "pike_prep_"
#define PORTALPREFIX	     "pike_portal_"
#define FACTORPLAN	     8
#define DRIVERNAME	     "pgsql"
#define MARKSTART            "{""{""{""{\n"   // split string to avoid
#define MARKERROR            ">>>>"	      // foldeditors from recognising
#define MARKEND              "\n}""}""}""}"   // it as a fold

#define ERROR(X ...)	     predef::error(X)

pgsql_result _portal;
int _nextportal;
int _closesent;
int _fetchlimit=FETCHLIMIT;
private int unnamedportalinuse;
private int portalsinflight;

private object conn;
private string SSauthdata,cancelsecret;
private int backendpid;
private int backendstatus;
private string lastmessage;
private mapping(string:array(mixed)) notifylist=([]);
private mapping(string:string) msgresponse;
private mapping(string:string) runtimeparameter;
private enum state {unauthenticated,authenticated,readyforquery,
 parsecomplete,bindcomplete,commandcomplete,gotrowdescription,
 gotparameterdescription,dataready,dataprocessed,portalsuspended,
 copyinresponse};
private state mstate;
private enum querystate {queryidle,inquery,cancelpending,canceled};
private querystate qstate;
private mapping(string:mapping(string:mixed)) prepareds=([]);
private int pstmtcount;
private int pportalcount;
private int totalhits;
private int cachedepth=1024; // Maximum cachecountsum for prepared statements,
			     // may be tuned by the application
private int timeout=4096;    // Queries running longer than this number of
			     // seconds are canceled automatically
private int portalbuffersize=64*1024;  // Approximate buffer per portal
private int reconnected;     // Number of times the connection was reset
private int flushed;

private string host, database, user, pass;
private int port;
private mapping(string:string) sessiondefaults=([]); // runtime parameters
private Thread.Mutex querymutex;
private Thread.Mutex stealmutex;

protected string _sprintf(int type, void|mapping flags) {
  string res=UNDEFINED;
  switch(type) {
    case 'O':
      res=sprintf(DRIVERNAME"://%s@%s:%d/%s pid:%d %s reconnected:%d\n"
       "mstate: %O  qstate: %O  pstmtcount: %d  pportalcount: %d\n"
       "Last query: %O\n"
       "Last message: %s\n"
       "Last error: %O\n"
       "portal %d %O\n%O\n",
       user,host,port,database,backendpid,status_commit(),reconnected,
       mstate,qstate,pstmtcount,pportalcount,
       _portal&&_portal->query||"",
       lastmessage||"",
       msgresponse,
       !!_portal,runtimeparameter,prepareds);
      break;
  }
  return res;
}

#define BOOLOID		16
#define BYTEAOID	17
#define CHAROID		18
#define INT8OID		20
#define INT2OID		21
#define INT4OID		23
#define TEXTOID		25
#define OIDOID		26
#define XMLOID		142
#define FLOAT4OID	700
#define MACADDROID	829
#define INETOID		869
#define BPCHAROID	1042
#define VARCHAROID	1043
#define CTIDOID		1247
#define UUIDOID		2950

#define PG_PROTOCOL(m,n)   (((m)<<16)|(n))
#define FLUSH		"H\0\0\0\4"

//! @decl void ereate()
//! @decl void create(string host, void|string database, void|string user,@
//!                   void|string password)
//!
//! With no arguments, this function initializes (reinitializes if a
//! connection had been previously set up) a connection to the
//! PostgreSQL backend. Since PostgreSQL requires a database to be
//! selected, it will try to connect to the default database. The
//! connection may fail however for a variety of reasons, in this case
//! the most likely of all is because you don't have enough authority
//! to connect to that database. So use of this particular syntax is
//! discouraged.
//!
//! The host argument can have the syntax @expr{"hostname"@} or
//! @expr{"hostname:portname"@}. This allows to specify the TCP/IP
//! port to connect to. If it is @expr{0@} or @expr{""@}, it will try
//! to connect to localhost, default port.
//!
//! The database argument specifies the database to connect to. If
//! @expr{0@} or @expr{""@}, it will try to connect to the specified
//! database.
//!
//! @note
//! You need to have a database selected before using the sql-object,
//! otherwise you'll get exceptions when you try to query it. Also
//! notice that this function @b{can@} raise exceptions if the db
//! server doesn't respond, if the database doesn't exist or is not
//! accessible by you.
//!
//! @seealso
//!   @[Postgres.postgres], @[Sql.Sql], @[postgres->select_db]
protected void create(void|string _host, void|string _database,
 void|string _user, void|string _pass) {
  pass = _pass; _pass = "CENSORED";
  user = _user; database = _database; host = _host || PGSQL_DEFAULT_HOST;
  if(search(host,":")>=0 && sscanf(_host,"%s:%d",host,port)!=2)
    ERROR("Error in parsing the hostname argument\n");
  if(!port)
    port = PGSQL_DEFAULT_PORT;
  querymutex=Thread.Mutex();
  stealmutex=Thread.Mutex();
  reconnect();
}

//! @decl string error()
//!
//! This function returns the textual description of the last
//! server-related error. Returns @expr{0@} if no error has occurred
//! yet. It is not cleared upon reading (can be invoked multiple
//! times, will return the same result until a new error occurs).
//!
//! To clear the error, pass 1 as argument.
//!
//! @seealso
//!   big_query
string error(void|int clear) {
  string s=lastmessage;
  if(clear)
    lastmessage=UNDEFINED;
  return s;
}

//! @decl string host_info()
//!
//! This function returns a string describing what host are we talking to,
//! and how (TCP/IP or UNIX sockets).

string host_info() {
  return sprintf("Via fd:%d over TCP/IP to %s:%d",conn->query_fd(),host,port);
}

final private int sendcmd(string|array(string) data,void|int flush) {
  if(flush) {
    if(stringp(data))
      data=({data,FLUSH});
    else
      data+=({FLUSH});
    PD("Flush\n");
    flushed=1;
  }
  else
    flushed=0;
  return conn.write(data);
}

final private void sendflush() {
  sendcmd(({}),1);
}

inline final private int getbyte() {
  if(!flushed && !conn.peek(0))
    sendflush();
#ifdef UNBUFFEREDIO
  return conn.read(1)[0];
#else
  return conn.getchar();
#endif
}

final private string getstring(int len) {
  string acc="",res;
  do {
    if(!flushed && !conn.peek(0))
      sendflush();
    res=conn.read(len,!flushed);
    if(res) {
      if(!sizeof(res))
        return acc;
      acc+=res;
    }
  }
  while(sizeof(acc)<len&&res);
  return sizeof(acc)?acc:res;
}

inline final private int getint16() {
  int s0=getbyte();
  int r=(s0&0x7f)<<8|getbyte();
  return s0&0x80 ? r-(1<<15) : r ;
}

inline final private int getint32() {
  int r=getint16();
  r=r<<8|getbyte();
  return r<<8|getbyte();
}

inline final private int getint64() {
  int r=getint32();
  r=r<<8|getbyte();
  r=r<<8|getbyte();
  r=r<<8|getbyte();
  return r<<8|getbyte();
}

#define plugstring(x)  (sprintf x)

#define plugbyte(x)    sprintf("%c",x)

inline final private string plugint16(int x) {
  return sprintf("%c%c",x>>8&255,x&255);
}

inline final private string plugint32(int x) {
  return sprintf("%c%c%c%c",x>>24&255,x>>16&255,x>>8&255,x&255);
}

inline final private string plugint64(int x) {
  return sprintf("%c%c%c%c%c%c%c%c",
   x>>56&255,x>>48&255,x>>40&255,x>>32&255,x>>24&255,x>>16&255,x>>8&255,x&255);
}

final private object getsocket() {
#ifdef UNBUFFEREDIO
  object lcon = Stdio.File();
#else
  object lcon = Stdio.FILE();
#endif
  return lcon.connect(host,port) && lcon;
}

//! Cancels the currently running query.
//!
//! This function is PostgreSQL-specific, and thus it is not available
//! through the generic SQL-interface.
void cancelquery() {
  if(qstate==inquery) {
    qstate=cancelpending;
    object lcon;
    PD("CancelRequest\n");
    if(!(lcon=getsocket()))
      ERROR("Cancel connect failed\n");
    lcon.write(({plugint32(16),plugint32(PG_PROTOCOL(1234,4567)),
     plugint32(backendpid),cancelsecret}));
    lcon.close();
  }
}

//! Returns the old cachedepth, sets the new cachedepth for prepared
//! statements automatic caching.
//!
//! This function is PostgreSQL-specific, and thus it is not available
//! through the generic SQL-interface.
int setcachedepth(void|int newdepth) {
  int olddepth=cachedepth;
  if(intp(newdepth) && newdepth>=0)
    cachedepth=newdepth;
  return olddepth;
}

//! Returns the old timeout, sets the new timeout for long running
//! queries.
//!
//! This function is PostgreSQL-specific, and thus it is not available
//! through the generic SQL-interface.
int settimeout(void|int newtimeout) {
  int oldtimeout=timeout;
  if(intp(newtimeout) && newtimeout>0)
    timeout=newtimeout;
  return oldtimeout;
}

//! Returns the old portalbuffersize, sets the new portalbuffersize
//! for buffering partially concurrent queries.
//!
//! This function is PostgreSQL-specific, and thus it is not available
//! through the generic SQL-interface.
int setportalbuffersize(void|int newportalbuffersize) {
  int oldportalbuffersize=portalbuffersize;
  if(intp(newportalbuffersize) && newportalbuffersize>0)
    portalbuffersize=newportalbuffersize;
  return oldportalbuffersize;
}

//! Returns the old fetchlimit, sets the new fetchlimit to interleave
//! queries.
//!
//! This function is PostgreSQL-specific, and thus it is not available
//! through the generic SQL-interface.
int setfetchlimit(void|int newfetchlimit) {
  int oldfetchlimit=_fetchlimit;
  if(intp(newfetchlimit) && newfetchlimit>=0)
    _fetchlimit=newfetchlimit;
  return oldfetchlimit;
}

final private string glob2reg(string glob) {
  if (!glob||!sizeof(glob))
    return "%";
  return replace(glob,({"*","?","\\","%","_"}),({"%","_","\\\\","\\%","\\_"}));
}

final private string addnlifpresent(void|string msg) {
  return msg?msg+"\n":"";
}

final private string pinpointerror(void|string query,void|string offset) {
  if(!query)
    return "";
  int k=(int)offset;
  if(k<=0)
    return MARKSTART+query+MARKEND;
  return MARKSTART+(k>1?query[..k-2]:"")+MARKERROR+query[k-1..]+MARKEND;
}

final private int decodemsg(void|state waitforstate) {
#ifdef DEBUG
  { array line;
#ifdef DEBUGMORE
    line=backtrace();
#endif
    PD("Waiting for state %O %O\n",waitforstate,line&&line[sizeof(line)-2]);
  }
#endif
  while(mstate!=waitforstate) {
    if(mstate!=unauthenticated) {
      if(qstate==cancelpending)
        qstate=canceled,sendclose();
      if(flushed && qstate==inquery && !conn.peek(0)) {
        int tcurr=time();
        int told=tcurr+timeout;
        while(!conn.peek(tcurr-told))
          if((tcurr=time())-told>=timeout) {
            sendclose();cancelquery();
            break;
          }
      }
    }
    int msgtype=getbyte();
    int msglen=getint32();
    enum errortype { noerror=0, protocolerror, protocolunsupported };
    errortype errtype=noerror;
    switch(msgtype) {
      void getcols() {
        int bintext=getbyte();
        array a;
        int cols=getint16();
        msglen-=4+1+2+2*cols;
        foreach(a=allocate(cols,([]));;mapping m)
          m->type=getint16();
        if(_portal) {
	  a=({(["type":bintext?BYTEAOID:TEXTOID,"name":"line"])});
	  _portal->_datarowdesc=a;
        }
        mstate=gotrowdescription;
      };
      array(string) getstrings() {
        string s;
        if(msglen<1)
          errtype=protocolerror;
        s=getstring(msglen);
        if(s[--msglen])
          errtype=protocolerror;
        if(!msglen)
          return ({});
        s=s[..msglen-1];msglen=0;
        return s/"\0";
      };
      void getresponse() {
        msglen-=4;
        msgresponse=([]);
        foreach(getstrings();;string f)
	  if(sizeof(f))
            msgresponse[f[..0]]=f[1..];
        PD("%O\n",msgresponse);
      };
      case 'R':PD("Authentication\n");
      { string sendpass;
        int authtype;
        msglen-=4+4;
        switch(authtype=getint32()) {
          case 0:PD("Ok\n");
	    mstate=authenticated;
            break;
          case 2:PD("KerberosV5\n");
            errtype=protocolunsupported;
            break;
          case 3:PD("ClearTextPassword\n");
            sendpass=pass;
            break;
          case 4:PD("CryptPassword\n");
            if(msglen<2)
              errtype=protocolerror;
            sendpass=getstring(msglen);msglen=0;
            errtype=protocolunsupported;
            break;
          case 5:PD("MD5Password\n");
            if(msglen<4)
              errtype=protocolerror;
#if constant(Crypto.MD5.hash)
#define md5hex(x) String.string2hex(Crypto.MD5.hash(x))
            sendpass=md5hex(pass+user);
            sendpass="md5"+md5hex(sendpass+getstring(msglen));
#else
            getstring(msglen);
            errtype=protocolunsupported;
#endif
            msglen=0;
            break;
          case 6:PD("SCMCredential\n");
            errtype=protocolunsupported;
            break;
          case 7:PD("GSS\n");
            errtype=protocolunsupported;
            break;
          case 9:PD("SSPI\n");
            errtype=protocolunsupported;
            break;
          case 8:PD("GSSContinue\n");
            errtype=protocolunsupported;
            if(msglen<1)
              errtype=protocolerror;
            SSauthdata=getstring(msglen);msglen=0;
            break;
          default:PD("Unknown Authentication Method %c\n",authtype);
            errtype=protocolunsupported;
            break;
        }
        switch(errtype) {
          case noerror:
            if(mstate==unauthenticated)
              sendcmd(({"p",plugint32(4+sizeof(sendpass)+1),
               sendpass,"\0"}));
            break;
          default:
          case protocolunsupported:
            ERROR("Unsupported authenticationmethod %c\n",authtype);
            break;
        }
        break;
      }
      case 'K':PD("BackendKeyData\n");
        msglen-=4+4;backendpid=getint32();cancelsecret=getstring(msglen);
        msglen=0;
        break;
      case 'S':PD("ParameterStatus\n");
        msglen-=4;
      { array(string) ts=getstrings();
        if(sizeof(ts)==2) {
          runtimeparameter[ts[0]]=ts[1];
          PD("%s=%s\n",ts[0],ts[1]);
        }
        else
          errtype=protocolerror;
      }
        break;
      case 'Z':PD("ReadyForQuery\n");
        msglen-=4+1;
        backendstatus=getbyte();
        mstate=readyforquery;
        qstate=queryidle;
        _closesent=0;
        break;
      case '1':PD("ParseComplete\n");
        msglen-=4;
        mstate=parsecomplete;
        break;
      case 't':
        PD("ParameterDescription (for %s)\n",
	 _portal?_portal->_portalname:"DISCARDED");
      { array a;
        int cols=getint16();
        msglen-=4+2+4*cols;
        foreach(a=allocate(cols);int i;)
	  a[i]=getint32();
#ifdef DEBUGMORE
        PD("%O\n",a);
#endif
        if(_portal)
	  _portal->_datatypeoid=a;
        mstate=gotparameterdescription;
        break;
      }
      case 'T':
        PD("RowDescription (for %s)\n",
	 _portal?_portal->_portalname:"DISCARDED");
        msglen-=4+2;
      { array a;
        foreach(a=allocate(getint16());int i;) {
          string s="",ts;
          while(msglen--,(ts=getstring(1))[0])
            s+=ts;
          mapping(string:mixed) res=(["name":s]);
          msglen-=4+2+4+2+4+2;
          res->tableoid=getint32()||UNDEFINED;
	  res->tablecolattr=getint16()||UNDEFINED;
          res->type=getint32();
	  { int len=getint16();
            res->length=len>=0?len:"variable";
	  }
          res->atttypmod=getint32();res->formatcode=getint16();
          a[i]=res;
        }
#ifdef DEBUGMORE
        PD("%O\n",a);
#endif
	if(_portal)
	  _portal->_datarowdesc=a;
        mstate=gotrowdescription;
        break;
      }
      case 'n':PD("NoData\n");
        msglen-=4;
        _portal->_datarowdesc=({});
        mstate=gotrowdescription;
        break;
      case '2':PD("BindComplete\n");
        msglen-=4;
        mstate=bindcomplete;
        break;
      case 'D':PD("DataRow\n");
        msglen-=4+2;
      { array a, datarowdesc;
        if(_portal) {
	  _portal->_bytesreceived+=msglen;
	  datarowdesc=_portal->_datarowdesc;
        }
        int cols=getint16();
        msglen-=4*cols;
        foreach(a=allocate(cols,"");int i;) {
          int collen=getint32();
          if(collen>0) {
            msglen-=collen;
            mixed value;
	    if(datarowdesc) {
              switch(datarowdesc[i]->type) {
	        default:value=getstring(collen);
                  break;
                case CHAROID:
                case BOOLOID:value=getbyte();
                  break;
                case INT8OID:value=getint64();
                  break;
                case FLOAT4OID:value=(float)getstring(collen);
                  break;
                case INT2OID:value=getint16();
                  break;
	        case OIDOID:
                case INT4OID:value=getint32();
              }
	      a[i]=value;
	    }
          }
          else if(collen)
            a[i]=UNDEFINED;	 // NULL
        }
        if(_portal)
	  _portal->_datarows+=({a}),_portal->_inflight--;
        mstate=dataready;
        break;
      }
      case 's':PD("PortalSuspended\n");
        msglen-=4;
        mstate=portalsuspended;
        break;
      case 'C':PD("CommandComplete\n");
      { msglen-=4;
        if(msglen<1)
          errtype=protocolerror;
        string s=getstring(msglen-1);
        if(_portal)
          _portal->_statuscmdcomplete=s;
        PD("%s\n",s);
        if(getbyte())
          errtype=protocolerror;
        msglen=0;
        mstate=commandcomplete;
        break;
      }
      case 'I':PD("EmptyQueryResponse\n");
        msglen-=4;
        mstate=commandcomplete;
        break;
      case '3':PD("CloseComplete\n");
        msglen-=4;
        _closesent=0;
        break;
      case 'd':PD("CopyData\n");
        msglen-=4;
        if(msglen<0)
          errtype=protocolerror;
        if(_portal) {
	  _portal->_bytesreceived+=msglen;
          _portal->_datarows+=({({getstring(msglen)})});
        }
	msglen=0;
        mstate=dataready;
        break;
      case 'H':PD("CopyOutResponse\n");
        getcols();
        if(_portal)
	  _portal->_fetchlimit=0;	  // disables further Executes
        break;
      case 'G':PD("CopyInResponse\n");
        getcols();
        mstate=copyinresponse;
        break;
      case 'c':PD("CopyDone\n");
        msglen-=4;
        break;
      case 'E':PD("ErrorResponse\n");
        getresponse();
        switch(msgresponse->C) {
          case "P0001":
            lastmessage=sprintf("%s: %s",msgresponse->S,msgresponse->M);
	    ERROR(lastmessage
	     +"\n"+pinpointerror(_portal->query,msgresponse->P));
	    break;
	  default:
            lastmessage=sprintf("%s %s:%s %s\n (%s:%s:%s)\n%s%s%s%s\n%s",
	     msgresponse->S,msgresponse->C,msgresponse->P||"",msgresponse->M,
	     msgresponse->F||"",msgresponse->R||"",msgresponse->L||"",
	     addnlifpresent(msgresponse->D),addnlifpresent(msgresponse->H),
	     pinpointerror(_portal&&_portal->query,msgresponse->P),
	     pinpointerror(msgresponse->q,msgresponse->p),
	     addnlifpresent(msgresponse->W));
            switch(msgresponse->S) {
	      case "PANIC":werror(lastmessage);
            }
	    ERROR(lastmessage);
        }
        break;
      case 'N':PD("NoticeResponse\n");
        getresponse();
        lastmessage=sprintf("%s %s: %s",
	 msgresponse->S,msgresponse->C,msgresponse->M);
        break;
      case 'A':PD("NotificationResponse\n");
      { msglen-=4+4;
        int pid=getint32();
        string condition,extrainfo=UNDEFINED;
        { array(string) ts=getstrings();
          switch(sizeof(ts)) {
            case 0:errtype=protocolerror;
	      break;
            default:errtype=protocolerror;
            case 2:extrainfo=ts[1];
            case 1:condition=ts[0];
          }
        }
        PD("%d %s\n%s\n",pid,condition,extrainfo);
        array cb;
        if((cb=notifylist[condition]||notifylist[""])
         && (pid!=backendpid || sizeof(cb)>1 && cb[1]))
	  cb[0](pid,condition,extrainfo,@cb[2..]);
        break;
      }
      default:PD("Unknown message received %c\n",msgtype);
        msglen-=4;PD("%O\n",getstring(msglen));msglen=0;
        errtype=protocolunsupported;
        break;
    }
    if(msglen)
      errtype=protocolerror;
    switch(errtype) {
      case protocolunsupported:
        ERROR("Unsupported servermessage received %c\n",msgtype);
        break;
      case protocolerror:
        reconnect(1);
        ERROR("Protocol error with databasel %s@%s:%d/%s\n",
         user,host,port,database);
        break;
      case noerror:
        break;
    }
    if(zero_type(waitforstate))
      break;
  }
  PD("Found state %O\n",mstate);
  return mstate;
}

private int read_cb(mixed foo, string d) {
  conn.unread(d);
  do decodemsg();
  while(conn.peek(0)==1);
  return 0;
}

final private void sendterminate() {
  PD("Terminate\n");
  sendcmd(({"X",plugint32(4)}));
  conn.close();
}

void destroy() {
  sendterminate();
}

private void reconnect(void|int force) {
  if(conn) {
    reconnected++;
#ifdef DEBUG
    ERROR("While debugging, reconnects are forbidden\n");
    exit(1);
#endif
    if(!force)
      sendterminate();
    foreach(prepareds;;mapping tprepared)
      m_delete(tprepared,"preparedname");
  }
  if(!(conn=getsocket()))
    ERROR("Couldn't connect to database on %s:%d\n",host,port);
  _closesent=0;
  mstate=unauthenticated;
  qstate=queryidle;
  runtimeparameter=([]);
  array(string) plugbuf=({"",plugint32(PG_PROTOCOL(3,0))});
  if(user)
    plugbuf+=({"user\0",user,"\0"});
  if(database)
    plugbuf+=({"database\0",database,"\0"});
  foreach(sessiondefaults;string name;string value)
    plugbuf+=({name,"\0",value,"\0"});
  plugbuf+=({"\0"});
  int len=4;
  foreach(plugbuf;;string s)
    len+=sizeof(s);
  plugbuf[0]=plugint32(len);
  sendcmd(plugbuf);
  PD("%O\n",plugbuf);
  decodemsg(readyforquery);
  PD("%O\n",runtimeparameter);
}

//! @decl void reload()
//!
//! Resets the connection to the database. Can be used for
//! a variety of reasons, for example to detect the status of a connection.
void reload(void|int special) {
  mixed err;
  int didsync;
  if(err = catch {
      sendclose();
      PD("Portalsinflight: %d\n",portalsinflight);
      if(!portalsinflight) {
        PD("Sync\n");
        sendcmd(({"S",plugint32(4)}),1);
        didsync=1;
        if(!special)
          decodemsg(readyforquery);
      }
    }) {
    PD("%O\n",err);
    reconnect(1);
  }
  else if(didsync && special==2)
    decodemsg(readyforquery);
#ifndef UNBUFFEREDIO
  conn.set_read_callback(read_cb);
#endif
}

//! @decl void select_db(string dbname)
//!
//! This function allows you to connect to a database. Due to
//! restrictions of the Postgres frontend-backend protocol, you always
//! have to be connected to a database, so in fact this function just
//! allows you to connect to a different database on the same server.
//!
//! @note
//! This function @b{can@} raise exceptions if something goes wrong
//! (backend process not running, not enough permissions..)
//!
//! @seealso
//!   create
void select_db(string dbname) {
  database=dbname;
  reconnect();
}

//! With PostgreSQL you can LISTEN to NOTIFY events.
//! This function allows you to detect and handle such events.
//!
//! @param condition
//!    Name of the notification event we're listening
//!    to.  A special case is the empty string, which matches all events,
//!    and can be used as fallback function which is called only when the
//!    specific condition is not handled..
//!
//! @param notify_cb
//!    Function to be called on receiving a notification-event of
//!    condition @[condition].
//!    The callback function is invoked with
//!     @expr{void notify_cb(pid,condition,extrainfo,@args);@}
//!    @[pid] is the process id of the database session that originated
//!    the event.  @[condition] contains the current condition.
//!    @[extrainfo] contains optional extra information specified by
//!    the database.
//!    The rest of the arguments to @[notify_cb] are passed
//!    verbatim from @[args].
//!    The callback function must return no value.
//! 
//! @param selfnotify
//!    Normally notify events generated by your own session are ignored.
//!    If you want to receive those as well, set @[selfnotify] to one.
//! 
//! @param args
//!    Extra arguments to pass to @[notify_cb].
//! 
//! This function is PostgreSQL-specific, and thus it is not available
//! through the generic SQL-interface.
void set_notify_callback(string condition,
 void|function(int,string,string,mixed ...:void) notify_cb,void|int selfnotify,
  mixed ... args) {
  if(!notify_cb)
    m_delete(notifylist,condition);
  else {
    array old=notifylist[condition];
    if(!old)
      old=({notify_cb});
    if(selfnotify||args)
      old+=({selfnotify});
    if(args)
      old+=args;
    notifylist[condition]=old;
  }
}

//! This function quotes magic characters inside strings embedded in a
//! textual query.  Quoting must not be done for parameters passed in
//! bindings.
//!
//! @seealso
//!   big_query
string quote(string s) {
  string r=runtimeparameter->standard_conforming_strings;
  if(r && r=="on")
    return replace(s, "'", "''");
  return replace(s, ({ "'", "\\" }), ({ "''", "\\\\" }) );
}

//! This function creates a new database with the given name (assuming we
//! have enough permissions to do this).
//!
//! @seealso
//!   drop_db
void create_db(string db) {
  big_query("CREATE DATABASE :db",([":db":db]));
}

//! This function destroys a database and all the data it contains (assuming
//! we have enough permissions to do so).
//!
//! @seealso
//!   create_db
void drop_db(string db) {
  big_query("DROP DATABASE :db",([":db":db]));
}

//! This function returns a string describing the server we are
//! talking to. It has the form @expr{"servername/serverversion"@}
//! (like the HTTP protocol description) and is most useful in
//! conjunction with the generic SQL-server module.
string server_info () {
  return DRIVERNAME"/"+(runtimeparameter->server_version||"unknown");
}

//! Lists all the databases available on the server.
//! If glob is specified, lists only those databases matching it.
array(string) list_dbs (void|string glob) {
 array row,ret=({});
 object res=big_query("SELECT d.datname "
  "FROM pg_database d "
  "WHERE d.datname ILIKE :glob "
  "ORDER BY d.datname",
  ([":glob":glob2reg(glob)]));
 while(row=res->fetch_row())
   ret+=({row[0]});
 return ret;
}

//! Returns an array containing the names of all the tables and views in the
//! path in the currently selected database.
//! If a glob is specified, it will return only those tables with matching
//! names.
array(string) list_tables (void|string glob) {
 array row,ret=({});  // This query might not work on PostgreSQL 7.4
 object res=big_query( // due to missing schemasupport
  "SELECT CASE WHEN 'public'=n.nspname THEN '' ELSE n.nspname||'.' END "
  "  ||c.relname AS name "
  "FROM pg_catalog.pg_class c "
  "  LEFT JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace "
  "WHERE c.relkind IN ('r','v') AND n.nspname<>'pg_catalog' "
  "  AND n.nspname !~ '^pg_toast' AND pg_catalog.pg_table_is_visible(c.oid) "
  "  AND c.relname ILIKE :glob "
  "  ORDER BY 1",
  ([":glob":glob2reg(glob)]));
 while(row=res->fetch_row())
   ret+=({row[0]});
 return ret;
}

//! Returns a mapping, indexed on the column name, of mappings describing
//! the attributes of a table of the current database.
//! If a glob is specified, will return descriptions only of the columns
//! matching it.
//!
//! The currently defined fields are:
//!
//! @mapping
//!   @member int "is_shared"
//!
//!   @member string "owner"
//!     Tableowner
//!
//!   @member string "length"
//!     Size of the columndatatype
//!
//!   @member string "text"
//!     A textual description of the internal (to the server) type-name
//!
//!   @member mixed "default"
//!     Default value for the column
//!
//!   @member mixed "schema"
//!     Schema the table belongs to
//!
//!   @member mixed "table"
//!     Name of the table
//!
//!   @member mixed "kind"
//!     Type of table
//!
//!   @member mixed "has_index"
//!     If the table has any indices
//!
//!   @member mixed "has_primarykey"
//!     If the table has a primary key
//!
//!   @member mixed "rowcount"
//!     Estimated rowcount of the table
//!
//!   @member mixed "pagecount"
//!     Estimated pagecount of the table
//!
//! @endmapping
//!
//! Setting wild to * will include system columns in the list.
//!
array(mapping(string:mixed)) list_fields(void|string table, void|string wild) {
  array row, ret=({});
  string schema=UNDEFINED;

  sscanf(table||"*", "%s.%s", schema, table);

  object res = big_query(
  "SELECT a.attname, a.atttypid, t.typname, a.attlen, "
  " c.relhasindex, c.relhaspkey, c.reltuples, c.relpages, "
  " c.relisshared, t.typdefault, "
  " n.nspname, c.relname, "
  " CASE c.relkind "
  "  WHEN 'r' THEN 'table' "
  "  WHEN 'v' THEN 'view' "
  "  WHEN 'i' THEN 'index' "
  "  WHEN 'S' THEN 'sequence' "
  "  WHEN 's' THEN 'special' "
  "  WHEN 't' THEN 'toastable' "    // pun intended :-)
  "  WHEN 'c' THEN 'composite' "
  "  ELSE c.relkind::TEXT END AS relkind, "
  " r.rolname "
  "FROM pg_catalog.pg_class c "
  "  LEFT JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace "
  "  JOIN pg_catalog.pg_roles r ON r.oid=c.relowner "
  "  JOIN pg_catalog.pg_attribute a ON c.oid=a.attrelid "
  "  JOIN pg_catalog.pg_type t ON a.atttypid=t.oid "
  "WHERE c.relname ILIKE :table AND "
  "  (n.nspname ILIKE :schema OR "
  "   :schema IS NULL "
  "   AND n.nspname<>'pg_catalog' AND n.nspname !~ '^pg_toast') "
  "   AND a.attname ILIKE :wild "
  "   AND (a.attnum>0 OR '*'=:realwild) "
  "ORDER BY n.nspname,c.relname,a.attnum,a.attname",
  ([":schema":glob2reg(schema),":table":glob2reg(table),
   ":wild":glob2reg(wild),":realwild":wild]));

  array colnames=res->fetch_fields();
  { mapping(string:string) renames=([
      "attname":"name",
      "nspname":"schema",
      "relname":"table",
      "rolname":"owner",
      "typname":"type",
      "attlen":"length",
      "typdefault":"default",
      "relisshared":"is_shared",
      "atttypid":"typeoid",
      "relkind":"kind",
      "relhasindex":"has_index",
      "relhaspkey":"has_primarykey",
      "reltuples":"rowcount",
      "relpages":"pagecount",
     ]);
    foreach(colnames;int i;mapping m) {
      string nf,field=m->name;
      if(nf=renames[field])
        field=nf;
      colnames[i]=field;
    }
  }

#define delifzero(m,field) if(!(m)[field]) m_delete(m,field)

  while(row=res->fetch_row()) {
    mapping m=mkmapping(colnames,row);
    delifzero(m,"is_shared");
    delifzero(m,"has_index");
    delifzero(m,"has_primarykey");
    delifzero(m,"default");
    ret+=({m});
  }
  return ret;
}

private int oidformat(int oid) {
  switch(oid) {
    case BOOLOID:
    case BYTEAOID:
    case CHAROID:
    case INT8OID:
    case INT2OID:
    case INT4OID:
    case TEXTOID:
    case OIDOID:
    case XMLOID:
    case MACADDROID:
    case INETOID:
    case BPCHAROID:
    case VARCHAROID:
    case CTIDOID:
    case UUIDOID:
      return 1; //binary
  }
  return 0; // text
}

final private void sendexecute(int fetchlimit) {
  string portalname=_portal->_portalname;
  PD("Execute portal %s fetchlimit %d\n",portalname,fetchlimit);
  sendcmd(({"E",plugint32(4+sizeof(portalname)+1+4),portalname,
   "\0",plugint32(fetchlimit)}),1);
  _portal->_inflight+=fetchlimit;
}

final private void sendclose() {
  string portalname;
  portalsinflight--;
  if(_portal && (portalname=_portal->_portalname)) {
    _portal->_portalname = UNDEFINED;
    _portal = UNDEFINED;
    if(!sizeof(portalname))
      unnamedportalinuse--;
#ifdef DEBUGMORE
    PD("Closetrace %O\n",backtrace());
#endif
    PD("Close portal %s\n",portalname);
    sendcmd(({"C",plugint32(4+1+sizeof(portalname)+1),
     "P",portalname,"\0"}));
    _closesent=1;
  }
}

final private string trbackendst(int c) {
  switch(c) {
    case 'I':return "idle";
    case 'T':return "intransaction";
    case 'E':return "infailedtransaction";
  }
  return "unknown";
}

//! Returns the current commitstatus of the connection.  Returns either one of:
//!  unknown
//!  idle
//!  intransaction
//!  infailedtransaction
//!
//! This function is PostgreSQL-specific, and thus it is not available
//! through the generic SQL-interface.
final string status_commit() {
  return trbackendst(backendstatus);
}

//! This is the only provided interface which allows you to query the
//! database. If you wish to use the simpler "query" function, you need to
//! use the @[Sql.Sql] generic SQL-object.
//!
//! It returns a pgsql_result object (which conforms to the
//! @[Sql.sql_result] standard interface for accessing data). I
//! recommend using @[query()] for simpler queries (because it is
//! easier to handle, but stores all the result in memory), and
//! @[big_query()] for queries you expect to return huge amounts of
//! data (it's harder to handle, but fetches results on demand).
//!
//! @note
//! This function @b{can@} raise exceptions.
//!
//! @seealso
//!   @[Sql.Sql], @[Sql.sql_result]
object big_query(string q,void|mapping(string|int:mixed) bindings) {
  string preparedname="";
  string portalname="";
  if(stringp(q) && String.width(q)>8)
    q=string_to_utf8(q);
  array(string|int) paramValues;
  if(bindings) {
    int pi=0,rep=0;
    paramValues=allocate(sizeof(bindings));
    array(string) from=allocate(sizeof(bindings));
    array(string) to=allocate(sizeof(bindings));
    foreach(bindings; mixed name; mixed value) {
      // Throws if mapping key is empty string.
      if(stringp(name)) {
        if(name[0]!=':')
          name=":"+name;
        if(name[1]=='_') {
          // Special parameter
          continue;
        }
      }
      from[rep]=name;
      string rval;
      if(multisetp(value)) {
        rval=sizeof(value) ? indices(value)[0] : "";
      }
      else {
        if(zero_type(value))
          paramValues[pi++]=UNDEFINED;	     // NULL
        else {
          if(stringp(value) && String.width(value)>8)
            value=string_to_utf8(value);
          paramValues[pi++]=value;
        }
        rval="$"+(string)pi;
      }
      to[rep++]=rval;
    }
    if(rep--)
      q=replace(q,from[..rep],to[..rep]);
    paramValues= pi ? paramValues[..pi-1] : ({});
  }
  else
    paramValues = ({});
  int tstart;
  mapping(string:mixed) tprepared;
  if(sizeof(q)>=MINPREPARELENGTH) {
    if(tprepared=prepareds[q]) {
      if(tprepared->preparedname)
        preparedname=tprepared->preparedname;
      else if((tstart=tprepared->trun)
       && tprepared->tparse*FACTORPLAN>=tstart)
	preparedname=PREPSTMTPREFIX+(string)pstmtcount++;
    }
    else {
      if(totalhits>=cachedepth) {
        array(string) plugbuf=({});
        foreach(prepareds;string ind;tprepared) {
	  int oldhits=tprepared->hits;
	  totalhits-=oldhits-(tprepared->hits=oldhits>>1);
	  if(oldhits<=1) {
	    string oldprep=tprepared->preparedname;
	    if(oldprep) {
	      PD("Close statement %s\n",oldprep);
              plugbuf+=({"C",plugint32(4+1+sizeof(oldprep)+1),
               "S",oldprep,"\0"});
	    }
	    m_delete(prepareds,ind);
	  }
        }
        if(sizeof(plugbuf))
	  sendcmd(plugbuf);	    // close expireds
        PD("%O\n",plugbuf);
      }
      prepareds[q]=tprepared=([]);
    }
    tstart=gethrtime();
  }  // pgsql_result autoassigns to portal
  pgsql_result(this,tprepared,q,_fetchlimit,portalbuffersize);
  if(unnamedportalinuse)
    portalname=PORTALPREFIX+(string)pportalcount++;
  else
    unnamedportalinuse++;
  _portal->_portalname=portalname;
  qstate=inquery;
  portalsinflight++;
  mixed err;
  if(err = catch {
      if(!sizeof(preparedname) || !tprepared || !tprepared->preparedname) {
        PD("Parse statement %s\n",preparedname);
        sendcmd(({"P",plugint32(4+sizeof(preparedname)+1+sizeof(q)+1+2),
         preparedname,"\0",q,"\0",plugint16(0)}));
        PD("Query: %O\n",q);
      }				 // sends Parameter- and RowDescription for 'S'
      PD("Describe statement %s\n",preparedname);
      conn.set_read_callback(0);
      sendcmd(({"D",plugint32(4+1+sizeof(preparedname)+1),
       "S",preparedname,"\0"}),1);
      { array(string) plugbuf=({"B",UNDEFINED});
        int len=4+sizeof(portalname)+1+sizeof(preparedname)+1
         +2+sizeof(paramValues)*(2+4)+2+2;
        plugbuf+=({portalname,"\0",preparedname,"\0",
         plugint16(sizeof(paramValues))});
        decodemsg(gotparameterdescription);
        array dtoid=_portal->_datatypeoid;
        foreach(dtoid;;int textbin)
          plugbuf+=({plugint16(oidformat(textbin))});
        plugbuf+=({plugint16(sizeof(paramValues))});
        foreach(paramValues;int i;mixed value) {
          if(zero_type(value))
            plugbuf+=({plugint32(-1)});	     // NULL
          else
            switch(dtoid[i]) {
              default:
              { int k;
                len+=k=sizeof(value=(string)value);
	        plugbuf+=({plugint32(k),value});
	        break;
              }
              case BOOLOID:plugbuf+=({plugint32(1)});len++;
                switch(stringp(value)?value[0]:value) {
		  case 'o':case 'O':
		    plugbyte(stringp(value)&&sizeof(value)>1
                     &&(value[1]=='n'||value[1]=='N'));
		    break;
                  case 0:case 'f':case 'F':case 'n':case 'N':
                    plugbuf+=({plugbyte(0)});
                    break;
                  default:
                    plugbuf+=({plugbyte(1)});
                    break;
                }
                break;
              case CHAROID:plugbuf+=({plugint32(1)});len++;
	        if(intp(value))
	          plugbuf+=({plugbyte(value)});
	        else {
		  value=(string)value;
		  if(sizeof(value)!=1)
		    ERROR("\"char\" types must be 1 byte wide, got %d\n",
		     sizeof(value));
	          plugbuf+=({value});
	        }
                break;
              case INT8OID:len+=8;
                plugbuf+=({plugint32(8),plugint64((int)value)});
                break;
              case INT4OID:len+=4;
                plugbuf+=({plugint32(4),plugint32((int)value)});
                break;
              case INT2OID:len+=2;
                plugbuf+=({plugint32(2),plugint16((int)value)});
                break;
            }
        }
        decodemsg(gotrowdescription);
        { array a;int i;
          len+=(i=sizeof(a=_portal->_datarowdesc))*2;
          plugbuf+=({plugint16(i)});
          foreach(a;;mapping col)
            plugbuf+=({plugint16(oidformat(col->type))});
        }
        plugbuf[1]=plugint32(len);
        PD("Bind portal %s statement %s\n",portalname,preparedname);
        sendcmd(plugbuf);
#ifdef DEBUGMORE
        PD("%O\n",plugbuf);
#endif
      }
      _portal->_statuscmdcomplete=UNDEFINED;
      sendexecute(_fetchlimit && FETCHLIMITLONGRUN);
      if(tprepared) {
        decodemsg(bindcomplete);
        int tend=gethrtime();
        if(tend==tstart)
	  m_delete(prepareds,q);
        else {
          tprepared->hit++;
          totalhits++;
	  if(!tprepared->preparedname) {
	    if(sizeof(preparedname))
	      tprepared->preparedname=preparedname;
	    tstart=tend-tstart;
	    if(tprepared->tparse>tstart)
	      tprepared->tparse=tstart;
	    else
	      tstart=tprepared->tparse;
	  }
	  tprepared->trunstart=tend;
        }
      }
    }) {
    PD("%O\n",err);
    reload(1);
    backendstatus=UNDEFINED;
    throw(err);
  }
  { pgsql_result tportal=_portal;   // Make copy, because it might dislodge
    tportal->fetch_row(1);	    // upon initial fetch_row()
    return tportal;
  }
}

//! This is an alias for @[big_query()], since @[big_query()] already supports
//! streaming of multiple simultaneous queries through the same connection.
//!
//! @seealso
//!   @[big_query], @[Sql.Sql], @[Sql.sql_result]
object streaming_query(string q,void|mapping(string|int:mixed) bindings) {
  return big_query(q,bindings);
}

class pgsql_result {

private object pgsqlsession;
private int numrows;
private int eoffound;
private mixed delayederror;
private int copyinprogress;
int _fetchlimit;

private mapping tprepared;
#ifdef NO_LOCKING
int _qmtxkey;
#else
Thread.MutexKey _qmtxkey;
#endif

string query;
string _portalname;

int _bytesreceived;
private int rowsreceived;
int _interruptable;
int _inflight;
string _statuscmdcomplete;
array(array(mixed)) _datarows;
array(mapping(string:mixed)) _datarowdesc;
array(int) _datatypeoid;

private object fetchmutex;;

protected string _sprintf(int type, void|mapping flags) {
  string res=UNDEFINED;
  switch(type) {
    case 'O':
      res=sprintf(DRIVERNAME"_result  numrows: %d  eof: %d  querylock: %d"
       " inflight: %d  portalname: %O\n"
       "query: %O\n"
       "laststatus: %s\n"
       "%O\n"
       "%O\n",
       numrows,eoffound,!!_qmtxkey,_inflight,_portalname,
       query,
       _statuscmdcomplete||"",
       _datarowdesc,
       pgsqlsession);
      break;
  }
  return res;
}

void create(object _pgsqlsession,mapping(string:mixed) _tprepared,
 string _query,int fetchlimit,int _portalbuffersize) {
  pgsqlsession = _pgsqlsession;
  tprepared = _tprepared; query = _query;
  _datarows = ({ }); numrows = UNDEFINED;
  fetchmutex = Thread.Mutex();
  _fetchlimit=fetchlimit;
  portalbuffersize=_portalbuffersize;
  steallock();
}

//! Returns the command-complete status for this query.
//!
//! This function is PostgreSQL-specific, and thus it is not available
//! through the generic SQL-interface.
//!
//! @seealso
//!  @[affected_rows]
string status_command_complete() {
  return _statuscmdcomplete;
}

//! Returns the number of affected rows by this query.
//!
//! This function is PostgreSQL-specific, and thus it is not available
//! through the generic SQL-interface.
//!
//! @seealso
//!  @[status_command_complete]
int affected_rows() {
  int rows;
  if(_statuscmdcomplete)
    sscanf(_statuscmdcomplete,"%*s %d",rows);
  return rows;
}

int num_fields() {
  return sizeof(_portal->datarowdesc);
}

int num_rows() {
  int numrows;
  sscanf(_statuscmdcomplete,"%*s %d",numrows);
  return numrows;
}

int eof() {
  return eoffound;
}

array(mapping(string:mixed)) fetch_fields() {
  return _datarowdesc+({});
}

private void releasesession() {
  if(pgsqlsession) {
    if(copyinprogress) {
      PD("CopyDone\n");
      pgsqlsession->sendmsg("c\0\0\0\4");
    }
    pgsqlsession->reload(2);
  }
  _qmtxkey=UNDEFINED;
  pgsqlsession=UNDEFINED;
}

void destroy() {
  catch {			 // inside destructors, exceptions don't work
    releasesession();
  };
}

inline private array(mixed) getdatarow() {
  array(mixed) datarow=_datarows[0];
  _datarows=_datarows[1..];
  return datarow;
}

private void steallock() {
#ifndef NO_LOCKING
  PD("Going to steal oldportal %d\n",!!pgsqlsession._portal);
  Thread.MutexKey stealmtxkey = stealmutex.lock();
  do
    if(_qmtxkey = querymutex.current_locking_key()) {
      pgsql_result portalb;
      if(portalb=pgsqlsession._portal) {
        pgsqlsession._nextportal++;
        if(portalb->_interruptable)
          portalb->fetch_row(2);
        else {
          PD("Waiting for the querymutex\n");
          if((_qmtxkey=querymutex.lock(2))) {
	    if(copyinprogress)
	      ERROR("COPY needs to be finished first\n");
	    ERROR("Driver bug, please report, "
             "conflict while interleaving SQL-operations\n");
	  }
          PD("Got the querymutex\n");
        }
        pgsqlsession._nextportal--;
      }
      break;
    }
  while(!(_qmtxkey=querymutex.trylock()));
#else
  PD("Skipping lock\n");
  _qmtxkey=1;
#endif
  pgsqlsession._portal=this;
  PD("Stealing successful\n");
}

int|array(string|int) fetch_row(void|int|string buffer) {
  if(copyinprogress) {
    if(stringp(buffer)) {
      PD("CopyData\n");
      pgsqlsession->sendmsg(({"d",plugint32(4+sizeof(buffer)),buffer}));
    }
    else
      releasesession();
    return UNDEFINED;
  }
#ifndef NO_LOCKING
  Thread.MutexKey fetchmtxkey = fetchmutex.lock();
#endif
  if(!buffer && sizeof(_datarows))
    return getdatarow();
  mixed err;
  if(buffer!=2 && (err=delayederror)) {
    delayederror=UNDEFINED;
    throw(err);
  }
  err = catch {
    if(_portalname) {
      if(buffer!=2 && !_qmtxkey) {
        steallock();
        sendexecute(_fetchlimit);
      }
      while(_closesent)
        decodemsg();		    // Flush previous portal sequence
      for(;;) {
#ifdef DEBUGMORE
        PD("buffer: %d  nextportal: %d  lock: %d\n",
	 buffer,pgsqlsession._nextportal,!!_qmtxkey);
#endif
        switch(decodemsg()) {
          case copyinresponse:
            copyinprogress=1;
	    return UNDEFINED;
          case dataready: {
            if(tprepared) {
              tprepared->trun=gethrtime()-tprepared->trunstart;
              m_delete(tprepared,"trunstart");
              tprepared = UNDEFINED;
            }
            mstate=dataprocessed;
            rowsreceived++;
	    switch(buffer) {
	      case 0:
	      case 1:
	        if(_fetchlimit)
	          _fetchlimit=
		   min(portalbuffersize/2*rowsreceived/_bytesreceived || 1,
	           pgsqlsession->_fetchlimit);
	    }
            switch(buffer) {
              case 2:
              case 3:
                continue;
              case 1:
	        _interruptable=1;
	        if(pgsqlsession._nextportal)
		  continue;
                return UNDEFINED;
            }
#if STREAMEXECUTES
	    if(_fetchlimit && _inflight<=_fetchlimit-1)
              sendexecute(_fetchlimit);	  // Overlap Executes
#endif
            return getdatarow();
          }
          case commandcomplete:
            releasesession();
	    switch(buffer) {
	      case 1:
	      case 2:
	        return UNDEFINED;
	      case 3:
	        if(sizeof(_datarows))
                  return getdatarow();
	    }
            break;
          case portalsuspended:
	    if(_inflight)
	      continue;
	    if(pgsqlsession._nextportal) {
	      switch(buffer) {
	        case 1:
	        case 2:
	          _qmtxkey = UNDEFINED;
                  return UNDEFINED;
	        case 3:
	          _qmtxkey = UNDEFINED;
                  return getdatarow();
	      }
              _fetchlimit=FETCHLIMITLONGRUN;
	      if(sizeof(_datarows)) {
	        _qmtxkey = UNDEFINED;
	        return getdatarow();
	      }
	      buffer=3;
	    }
            sendexecute(_fetchlimit);
          default:
            continue;
        }
        break;
      }
    }
    eoffound=1;
    return UNDEFINED;
  };
  PD("Exception %O\n",err);
  pgsqlsession->reload();
  if(buffer!=2)
    throw(err);
  if(!delayederror)
    delayederror=err;
  return UNDEFINED;
}

};