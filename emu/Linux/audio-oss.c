#include "dat.h"
#include "fns.h"
#include "error.h"
#include "audio.h"
#include <sys/ioctl.h>
#include <sys/soundcard.h>

#define 	Audio_Mic_Val		SOUND_MIXER_MIC
#define 	Audio_Linein_Val	SOUND_MIXER_LINE

#define		Audio_Speaker_Val	SOUND_MIXER_PCM // SOUND_MIXER_VOLUME
#define		Audio_Headphone_Val	SOUND_MIXER_ALTPCM
#define		Audio_Lineout_Val	SOUND_MIXER_CD

#define 	Audio_Pcm_Val		AFMT_S16_LE
#define 	Audio_Ulaw_Val		AFMT_MU_LAW
#define 	Audio_Alaw_Val		AFMT_A_LAW

#include "audio-tbls.c"
#define	min(a,b)	((a) < (b) ? (a) : (b))

#define DEVAUDIO	"/dev/dsp"
#define DEVMIXER	"/dev/mixer"

#define DPRINT if(0)print

enum {
	A_Pause,
	A_UnPause,
	A_In,
	A_Out,
};

static struct {
	int data;	/* dsp data fd */
	int ctl;	/* mixer fd */
	int pause;
	QLock lk;
} afd = {.data = -1, .ctl = -1, .pause =A_UnPause };

static Audio_t av;
static QLock inlock;
static QLock outlock;

static int audio_open(int);
static int audio_pause(int, int);
static int audio_set_info(int, Audio_d*, int);

/*
 * Output decoupling.  The OSS shim (and OSS hardware) accepts data
 * in fragment-sized bursts and its socket buffer is exactly one
 * fragment, so the game's 315-byte-per-tic writes periodically block
 * the tic loop and produce frame judder.  Vanilla Doom decouples
 * with a sound thread; do the same: writes are copied into a ring
 * and a kproc drains it into the device, absorbing any blocking.
 * Steady state keeps the ring near empty (no added latency beyond
 * the device buffer).
 */
enum {
	AQSHIFT	= 15,
	AQSIZE	= 1 << AQSHIFT,	/* 32KB ~= 3s of 11025Hz u8 */
	AQMASK	= AQSIZE - 1,
};

static struct {
	Lock	lk;
	Rendez	r;
	uchar	*b;
	int	rp;		/* read index in b */
	int	n;		/* bytes queued */
	int	fd;		/* device fd drained by the writer */
	int	running;
	int	stop;
} aq;

static int
aqready(void *a)
{
	USED(a);
	return aq.n > 0 || aq.stop;
}

static void
aqwriter(void *a)
{
	uchar tmp[4096];
	int fd, n, k;

	USED(a);
	for(;;){
		lock(&aq.lk);
/* Sleep does not release caller locks: drop aq.lk while
		 * blocked; Sleep re-checks aqready so a Wakeup racing the
		 * unlock is not lost. */
		while(aq.n == 0 && !aq.stop){
			unlock(&aq.lk);
			Sleep(&aq.r, aqready, nil);
			lock(&aq.lk);
		}
if(aq.n == 0){
			/* stop requested and everything played out */
			fd = aq.fd;
			aq.fd = -1;
			aq.running = 0;
			unlock(&aq.lk);
			if(fd >= 0)
				close(fd);
			return;
		}
		n = aq.n;
		if(n > sizeof tmp)
			n = sizeof tmp;
		k = AQSIZE - aq.rp;
		if(k > n)
			k = n;
		memmove(tmp, aq.b + aq.rp, k);
		if(n > k)
			memmove(tmp + k, aq.b, n - k);
		aq.rp = (aq.rp + n) & AQMASK;
		aq.n -= n;
		fd = aq.fd;
		unlock(&aq.lk);
		/* only this thread ever blocks on the device */
if(fd >= 0)
			write(fd, tmp, n);
	}
}

static void
aqenqueue(uchar *p, long n)
{
	int k, w;

lock(&aq.lk);
if(aq.b == nil && (aq.b = malloc(AQSIZE)) == nil){
		unlock(&aq.lk);
		return;			/* drop: no memory */
	}
	if(!aq.running && aq.fd >= 0){
		aq.running = 1;
		aq.stop = 0;
kproc("audiowrite", aqwriter, nil, 0);
}
	if(n > AQSIZE - aq.n)
		n = AQSIZE - aq.n;	/* overflow: drop (3s buffer) */
	w = (aq.rp + aq.n) & AQMASK;
	k = AQSIZE - w;
	if(k > n)
		k = n;
	memmove(aq.b + w, p, k);
	if(n > k)
		memmove(aq.b, p + k, n - k);
	aq.n += n;
	Wakeup(&aq.r);
	unlock(&aq.lk);
}

Audio_t*
getaudiodev(void)
{
	return &av;
}

void 
audio_file_init(void)
{
	audio_info_init(&av);
}

void
audio_file_open(Chan *c, int omode)
{
	USED(c);
	DPRINT("audio_file_open %d %d %x\n", afd.data, afd.ctl, omode);
	qlock(&afd.lk);
	if(waserror()){
		qunlock(&afd.lk);
		nexterror();
	}
	if(afd.data >= 0)
		error(Einuse);
	if(afd.ctl < 0){
		afd.ctl = open(DEVMIXER, ORDWR);
		if(afd.ctl < 0)
			oserror();
	}
	afd.data = audio_open(omode);
	if(afd.data < 0)
		oserror();
	poperror();
	qunlock(&afd.lk);
}

void    
audio_file_close(Chan *c)
{
	USED(c);
	DPRINT("audio_file_close %d %d\n", afd.data, afd.ctl);
	qlock(&afd.lk);
	if(waserror()){
		qunlock(&afd.lk);
		nexterror();
	}
	/* stop the writer (it owns the fd and closes it after the
	 * ring has played out) and wait for it to finish, so a later
	 * open never races the old fd */
	lock(&aq.lk);
	aq.stop = 1;
	Wakeup(&aq.r);
	unlock(&aq.lk);
	for(;;){
		lock(&aq.lk);
		if(!aq.running){
			unlock(&aq.lk);
			break;
		}
		unlock(&aq.lk);
		osmillisleep(1);
	}
	afd.data = -1;
	qunlock(&afd.lk);
	poperror();
}

long
audio_file_read(Chan *c, void *va, long count, vlong offset)
{
	long ba, status, chunk, total;

	USED(c);
	USED(offset);
	DPRINT("audio_file_read %d %d\n", afd.data, afd.ctl);
	qlock(&inlock);
	if(waserror()){
		qunlock(&inlock);
		nexterror();
	}

	if(afd.data < 0)
		error(Eperm);

	/* check block alignment */
	ba = av.in.bits * av.in.chan / Bits_Per_Byte;

	if(count % ba)
		error(Ebadarg);
		
	if(!audio_pause(afd.data, A_UnPause))
		error(Eio);
	
	total = 0;
	while(total < count){
		chunk = count - total;
		status = read (afd.data, va + total, chunk);
		if(status < 0)
			error(Eio);
		total += status;
	}
	
	if(total != count)
		error(Eio);

	poperror();
	qunlock(&inlock);
	
	return count;
}

long
audio_file_write(Chan *c, void *va, long count, vlong offset)
{
	long ba, bufsz;

	USED(c);
	USED(offset);
	DPRINT("audio_file_write %d %d\n", afd.data, afd.ctl);
	qlock(&outlock);
	if(waserror()){
		qunlock(&outlock);
		nexterror();
	}
	
	if(afd.data < 0)
		error(Eperm);
	
	/* check block alignment */
	ba = av.out.bits * av.out.chan / Bits_Per_Byte;

	if(count % ba)
		error(Ebadarg);

	bufsz = av.out.buf * Audio_Max_Buf / Audio_Max_Val;
	if(bufsz == 0)
		error(Ebadarg);

	/* decoupled: the writer kproc absorbs device blocking */
	aqenqueue(va, count);

	poperror();
	qunlock(&outlock);

	return count;
}

long
audio_ctl_write(Chan *c, void *va, long count, vlong offset)
{
	Audio_t tmpav = av;
	int tfd;

	USED(c);
	USED(offset);
	tmpav.in.flags = 0;
	tmpav.out.flags = 0;
	
	DPRINT ("audio_ctl_write %X %X\n", afd.data, afd.ctl);
	if(!audioparse(va, count, &tmpav))
		error(Ebadarg);

	if(!canqlock(&inlock))
		error("device busy");
	if(waserror()){
		qunlock(&inlock);
		nexterror();
	}
	if(!canqlock(&outlock))
		error("device busy");
	if(waserror()){
		qunlock(&outlock);
		nexterror();
	}

	/* DEVAUDIO needs to be open to issue an ioctl */
	tfd = afd.data;
	if(tfd < 0){
		tfd = open(DEVAUDIO, O_RDONLY|O_NONBLOCK);
		if(tfd < 0)
			oserror();
	}
	if(waserror()){
		if(tfd != afd.data)
			close(tfd);
		nexterror();
	}

	if(tmpav.in.flags & AUDIO_MOD_FLAG){
		if(!audio_pause(tfd, A_Pause))
			error(Ebadarg);
		if(!audio_set_info(tfd, &tmpav.in, A_In))
			error(Ebadarg);
	}

	poperror();
	if(tfd != afd.data)
		close(tfd);

	tmpav.in.flags = 0;
	av = tmpav;

	poperror();
	qunlock(&outlock);
	poperror();
	qunlock(&inlock);
	return count;
}

/* Linux/OSS specific stuff */

static int
choosefmt(Audio_d *i)
{
	switch(i->bits){
	case 8:
		switch(i->enc){
		case Audio_Alaw_Val:
			return AFMT_A_LAW;
		case Audio_Ulaw_Val:
			return AFMT_MU_LAW;
		case Audio_Pcm_Val:
			return AFMT_U8;
		}
		break;
	case 16:
		if(i->enc == Audio_Pcm_Val)
			return AFMT_S16_LE;
		break;
	}
	return -1;
}

static int
setvolume(int fd, int what, int left, int right)
{
	int can, v;
	
	if(ioctl(fd, SOUND_MIXER_READ_DEVMASK, &can) < 0)
		can = ~0;

	DPRINT("setvolume fd%d %X can mix 0x%X (mask %X)\n", fd, what, (can & (1<<what)), can);
	if(!(can & (1<<what)))
		return 0;
	v = left | (right<<8);
	if(ioctl(afd.ctl, MIXER_WRITE(what), &v) < 0)
		return 0;
	return 1;
}

static int
audio_set_info(int fd, Audio_d *i, int d)
{
	int status, arg;
	int oldfmt, newfmt;

	USED(d);
	DPRINT("audio_set_info (%d) %d %d\n", fd, afd.data, afd.ctl);
	if(fd < 0)
		return 0;

	/* sample rate */
	if(i->flags & AUDIO_RATE_FLAG){
		arg = i->rate;
		if(ioctl(fd, SNDCTL_DSP_SPEED, &arg) < 0)
			return 0;
	}
	
	/* channels */
	if(i->flags & AUDIO_CHAN_FLAG){
		arg = i->chan;
		if(ioctl(fd, SNDCTL_DSP_CHANNELS, &arg) < 0)
			return 0;
	}

	/* precision */
	if(i->flags & AUDIO_BITS_FLAG){
		arg = i->bits;
		if(ioctl(fd, SNDCTL_DSP_SAMPLESIZE, &arg) < 0)
			return 0;
	}
	
	/* encoding */
	if(i->flags & AUDIO_ENC_FLAG){
		ioctl(fd, SNDCTL_DSP_GETFMTS, &oldfmt);

		newfmt = choosefmt(i);
		if(newfmt < 0)
			return 0;
		if(newfmt != oldfmt){
			status = ioctl(fd, SNDCTL_DSP_SETFMT, &newfmt);
			DPRINT ("enc oldfmt newfmt %x status %d\n", oldfmt, newfmt, status);
		}
	}

	/* dev volume */
	/* Non-fatal: shim mixers (padsp/PA) report partial devmasks, and
	 * a failed volume-set must not abort the device open. */
	if(i->flags & (AUDIO_LEFT_FLAG|AUDIO_VOL_FLAG))
		setvolume(afd.ctl, i->dev, i->left, i->right);

	return 1;
}

static int
audio_set_blocking(int fd)
{
	int val;

	if((val = fcntl(fd, F_GETFL, 0)) == -1)
		return 0;
	
	val &= ~O_NONBLOCK;

	if(fcntl(fd, F_SETFL, val) < 0)
		return 0;

	return 1;
}

static int
audio_open(int omode)
{
	int fd;
	
	/* open non-blocking in case someone already has it open */
	/* otherwise we would block until they close! */
	switch (omode){
	case OREAD:
		fd = open(DEVAUDIO, O_RDONLY|O_NONBLOCK);
		break;
	case OWRITE:
		fd = open(DEVAUDIO, O_WRONLY|O_NONBLOCK);
		break;
	case ORDWR:
		fd = open(DEVAUDIO, O_RDWR|O_NONBLOCK);
		break;
	}

	DPRINT("audio_open %d\n", fd);
	if(fd < 0)
		oserror();

	/* change device to be blocking */
	if(!audio_set_blocking(fd)){
		close(fd);
		error("cannot set blocking mode");
	}

	/* Small DMA fragments: keeps the PulseAudio shim's stream
	 * buffer at fragment*nfrag bytes (~93ms at 11025Hz) instead of
	 * its ~1.1s default (12x1024), cutting sound latency.  Fragment
	 * size must exceed the game's 315-byte per-tic writes, or every
	 * write blocks in the shim's fragment-sized socket buffer and
	 * stalls the tic loop.  Non-fatal: real OSS drivers round the
	 * request their own way. */
	{
		int farg = (2 << 16) | 9;	/* 2 fragments of 512 bytes */
		ioctl(fd, SNDCTL_DSP_SETFRAGMENT, &farg);
	}

	if(!audio_pause(fd, A_Pause)){
		close(fd);
		error(Eio);
	}

	/* set audio info */
	av.in.flags = ~0;
	av.out.flags = ~0;

	if(!audio_set_info(fd, &av.in, A_In)){
		close(fd);
		error(Ebadarg);
	}

	av.in.flags = 0;

	/* hand the device to the writer kproc (it drains and, on
	 * close, owns the fd) */
	lock(&aq.lk);
	aq.fd = fd;
	unlock(&aq.lk);

	/* tada, we're open, blocking, paused and flushed */
	return fd;
}

static int
dspsync(int fd)
{
	return ioctl(fd, SNDCTL_DSP_RESET, NULL) >= 0 &&
		ioctl(fd, SNDCTL_DSP_SYNC, NULL) >= 0;
}

static int
audio_pause(int fd, int f)
{
	int status;

//	DPRINT ("audio_pause (%d) %d %d\n", fd, afd.data, afd.ctl);
	if(fd < 0)
		return 0;
	if(fd != afd.data)
		return dspsync(fd);
	qlock(&afd.lk);
	if(afd.pause == f){
		qunlock(&afd.lk);
		return 1;
	}
	if(waserror()){
		qunlock(&afd.lk);
		nexterror();
	}
	status = dspsync(afd.data);
	if(status)
		afd.pause = f;
	poperror();
	qunlock(&afd.lk);
	return status;
}
