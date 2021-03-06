#pike __REAL_VERSION__
#pragma strict_types
// $Id$

//! This module contains stuff to that tries to give you the
//! best possible random generation.

#if constant(Nettle) && constant(Nettle.Yarrow)

#if constant(Nettle.NT)

class Source {
  static Nettle.NT.CryptContext ctx;

  static void create(int(0..1) no_block) {
    ctx = Nettle.NT.CryptContext(0, 0, Nettle.NT.PROV_RSA_FULL,
				 Nettle.NT.CRYPT_VERIFYCONTEXT );
    no_block;	// Fix warning.
  }

  string read(int bytes) {
    return ctx->read(bytes);
  }
}

#else

class Source {
  static Stdio.File f;
  static string data = "";
  static int factor = 2; // Assume 50% entropy

  static void create(int(0..1) no_block) {
    if(no_block) {
      if(file_stat("/dev/urandom"))
	f = Stdio.File("/dev/urandom");
    }
    else {
      if(file_stat("/dev/random")) {
	if(file_stat("/dev/urandom")) factor = 1;
	f = Stdio.File("/dev/random");
      }
      else if(file_stat("/dev/urandom"))
	f = Stdio.File("/dev/urandom");
    }
  }

  string read(int bytes) {
    bytes *= factor;
    if(f) return f->read(bytes);
    bytes *= 4;
    while(sizeof(data)<bytes)
      data += get_data();
    string ret = data[..bytes-1];
    data = data[bytes..];
    return ret;
  }

  static string get_data() {
    Stdio.File f = Stdio.File();
    Stdio.File child_pipe = f->pipe();
    if(!child_pipe) error("Could not generate random data.\n");

    // Attempt to generate some entropy by running some
    // statistical commands.
    mapping(string:string) env = [mapping(string:string)]getenv() + ([
      "PATH":"/usr/sbin:/usr/etc:/usr/bin/:/sbin/:/etc:/bin",
    ]);
    mapping(string:mixed) modifiers = ([
      "stdin":Stdio.File("/dev/null", "rw"),
      "stdout":child_pipe,
      "stderr":child_pipe,
      "env":env,
    ]);
    foreach(({ ({ "last", "-256" }),
	       ({ "arp", "-a" }),
	       ({ "netstat", "-anv" }), ({ "netstat", "-mv" }),
	       ({ "netstat", "-sv" }),
	       ({ "uptime" }),
	       ({ "ps", "-fel" }), ({ "ps", "aux" }),
	       ({ "vmstat", "-f" }), ({ "vmstat", "-s" }),
	       ({ "vmstat", "-M" }),
	       ({ "iostat" }), ({ "iostat", "-t" }),
	       ({ "iostat", "-cdDItx" }),
	       ({ "ipcs", "-a" }),
	       ({ "pipcs", "-a" }),
    }), array(string) cmd) {
      catch {
	Process.create_process(cmd, modifiers);
      };
    }
    child_pipe->close();
    destruct(child_pipe);
    data = f->read();
    f->close();
  }
}

#endif

static class RND {
  inherit Nettle.Yarrow;
  static int bytes_left = 32;

  static Source s;

  static int last_tick;
  static function(void:int) ticker;

  static void create(int(0..1) no_block) {
    // Source 0: /dev/random or CryptGenRandom
    // Source 1: ticker
    // Source 2: external
    ::create(3);
    s = Source(no_block);
    seed( s->read(min_seed_size()) );

#if constant(System.rdtsc)
    ticker = System.rdtsc;
#elif constant(gethrtime)
    ticker = gethrtime;
#else
    ticker = time;
#endif
  }

  static Thread.Mutex lock = Thread.Mutex();

  string random_string(int len) {
    object key = lock->lock();
    return low_random_string(len);
    key = 0;	// Fix warning.
  }

  string low_random_string(int len) {
    String.Buffer buf = String.Buffer(len);
    int new_tick = ticker();
    update( (string)(new_tick-last_tick), 1, 1 );
    last_tick = new_tick;

    while(len) {
      int pass = min(len, bytes_left);
      buf->add( ::random_string(pass) );
      bytes_left -= pass;
      len -= pass;
      if(bytes_left - pass <= 0) {
	update( s->read(32), 0, 256 );
	bytes_left += 32;
      }
    }
    return (string)buf;
  }
}

static string rnd_bootstrap(int len) {
  rnd_obj = RND(1);
  rnd_func = rnd_obj->random_string;
  return rnd_func(len);
}

static RND rnd_obj;
static function(int:string) rnd_func = rnd_bootstrap;

static string rnd_block_bootstrap(int len) {
  rnd_block_obj = RND(0);
  rnd_block_func = rnd_block_obj->random_string;
  return rnd_block_func(len);
}

static RND rnd_block_obj;
static function(int:string) rnd_block_func = rnd_block_bootstrap;

//! Returns a string of length @[len] with random content. The
//! content is generated by a Yarrow random generator that is
//! constantly updated with output from /dev/random on UNIX and
//! CryptGenRandom on NT. The Yarrow random generator is fed
//! at least the amount of random data from its sources as it
//! outputs, thus doing its best to give at least good pseudo-
//! random data on operating systems with bad /dev/random.
string random_string(int len) {
  return rnd_func(len);
}

//! Returns a @[Gmp.mpz] object with a random value between @expr{0@}
//! and @[top]. Uses @[random_string].
Gmp.mpz random(int top) {
  return [object(Gmp.mpz)]( Gmp.mpz(rnd_func( (int)ceil( log((float)top)/
							 log(2.0) ) ),
				    256) % top);
}

//! Works as @[random_string], but may block in order to gather enough
//! entropy to make a truely random output. Using this function is
//! probably overkill for about all applications.
string blocking_random_string(int len) {
  return rnd_block_func(len);
}

//! Inject additional entropy into the random generator.
//! @param data
//!   The random string.
//! @param entropy
//!   The number of bits in the random string that is
//!   truely random.
void add_entropy(string data, int entropy) {
  if(rnd_obj)
    rnd_obj->update(data, 2, entropy);
  if(rnd_block_obj)
    rnd_block_obj->update(data, 2, entropy);
}

#else
constant this_program_does_not_exist=1;
#endif
