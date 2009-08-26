#include "perl_mongo.h"
#include "mongo_link.h"

extern int request_id;

static int already_queried(SV *self) {
  // check if the query's been executed
  return SvTRUE(perl_mongo_call_reader (self, "_queried"));
}

static mongo_cursor* get_cursor(SV *self) {
  SV **link_sv;
  mongo_link *link;
  mongo_cursor *cursor;
  buffer buf;
  mongo_msg_header header;
  int sent;

  cursor = (mongo_cursor*)perl_mongo_get_ptr_from_instance(self);

  // if so, get the cursor
  if (cursor->started_iterating) {
    return cursor;
  }

  link_sv = hv_fetch(SvSTASH(SvRV(self)), "link", strlen("link"), 0);
  link = (mongo_link*)perl_mongo_get_ptr_from_instance(*link_sv);

  // if not, execute the query
  CREATE_BUF(INITIAL_BUF_SIZE);
  CREATE_HEADER_WITH_OPTS(buf, cursor->ns, OP_QUERY, cursor->opts);
  serialize_int(&buf, cursor->skip);
  serialize_int(&buf, cursor->limit);
  perl_mongo_sv_to_bson(&buf, cursor->query, "MongoDB::OID");
  if (cursor->fields) {
    perl_mongo_sv_to_bson(&buf, cursor->fields, "MongoDB::OID");
  }

  serialize_size(buf.start, &buf);

  // sends
  sent = mongo_link_say(link, &buf);
  Safefree(buf.start);
  if (sent == -1) {
    croak("couldn't send query.");
  }

  mongo_link_hear(link, cursor);
  cursor->started_iterating = 1;

  return cursor;
}

static int _has_next(SV *self, mongo_cursor *cursor) {
  SV **link_sv;
  mongo_link *link;
  mongo_msg_header header;
  buffer buf;
  int size;

  if ((cursor->limit > 0 && cursor->at >= cursor->limit) || 
      cursor->num == 0 ||
      (cursor->at == cursor->num && cursor->cursor_id == 0)) {
    return 0;
  }
  else if (cursor->at < cursor->num) {
    return 1;
  }


  link_sv = hv_fetch(SvSTASH(SvRV(self)), "link", strlen("link"), 0);
  link = (mongo_link*)perl_mongo_get_ptr_from_instance(*link_sv);

  // we have to go and check with the db
  size = 34+strlen(cursor->ns);
  Newx(buf.start, size, char);
  buf.pos = buf.start;
  buf.end = buf.start + size;

  CREATE_RESPONSE_HEADER(buf, cursor->ns, cursor->header.request_id, OP_GET_MORE);
  serialize_int(&buf, cursor->limit);
  serialize_long(&buf, cursor->cursor_id);
  serialize_size(buf.start, &buf);

  // fails if we're out of elems
  if(mongo_link_say(link, &buf) == -1) {
    Safefree(buf.start);
    return 0;
  }

  Safefree(buf.start);

  // if we have cursor->at == cursor->num && recv fails,
  // we're probably just out of results
  // mongo_link_hear returns 0 on success
  return (mongo_link_hear(link, cursor) == 0);
}


MODULE = MongoDB::Cursor  PACKAGE = MongoDB::Cursor

PROTOTYPES: DISABLE


bool
has_next (self)
        SV *self
    PREINIT:
        mongo_cursor *cursor;
        mongo_link *link;
    CODE:
        cursor = get_cursor(self);
        RETVAL = _has_next(self, cursor);
    OUTPUT:
        RETVAL

SV *
next (self)
        SV *self
    PREINIT:
        mongo_cursor *cursor;
    CODE:
        cursor = get_cursor(self);
        if (_has_next(self, cursor)) {
          RETVAL = perl_mongo_bson_to_sv("MongoDB::OID", &cursor->buf);
          cursor->at++;

          //TODO handle $err
	} else {
          RETVAL = &PL_sv_undef;
        }
    OUTPUT:
        RETVAL


SV *
snapshot (self)
        SV *self
    PREINIT:
        mongo_cursor *cursor;
        HV *this_hash;
        SV **query;
    CODE:
        cursor = (mongo_cursor*)perl_mongo_get_ptr_from_instance(self);
        if (cursor->started_iterating) {
          croak("cannot set snapshot() after query");
          return;
        }

        this_hash = SvSTASH(SvRV(self));
        query = hv_fetch(this_hash, "query", strlen("query"), 0);

        if (query && SvROK(*query) && SvTYPE(SvRV(*query)) == SVt_PVHV) {
          // store $snapshot
          SV **ret = hv_store((HV*)SvRV(*query), "$snapshot", strlen("$snapshot"), newSViv(1), 0);
        }
        // increment this
        SvREFCNT_inc(self);


SV *
sort (self, sort)
        SV *self
        SV *sort
     PREINIT:
        mongo_cursor *cursor;
        HV *this_hash;
        SV **query;
     CODE:
        cursor = (mongo_cursor*)perl_mongo_get_ptr_from_instance(self);
        if (cursor->started_iterating) {
          croak("cannot set sort() after query");
          return;
        }

        this_hash = SvSTASH(SvRV(self));
        query = hv_fetch(this_hash, "query", strlen("query"), 0);

        if (query && SvROK(*query) && SvTYPE(SvRV(*query)) == SVt_PVHV) {
          // store sort and increase refcount
          SV **ret = hv_store((HV*)SvRV(*query), "orderby", strlen("orderby"), SvREFCNT_inc(sort), 0);

          // if the hash update failed, decrement the refcount
          if (!ret) {
            SvREFCNT_dec(sort);
            // should we croak here?
          }
        } else {
          croak("something is wrong with the query");
        }
        // increment this
        SvREFCNT_inc(self);

SV *
limit (self, num)
        SV *self
        int num
     PREINIT:
        mongo_cursor *cursor;
        HV *this_hash;
     CODE:
        cursor = (mongo_cursor*)perl_mongo_get_ptr_from_instance(self);
        if (cursor->started_iterating) {
          croak("cannot set limit() after query");
          return;
        }

        this_hash = SvSTASH(SvRV(self));

        // store limit
        hv_store(this_hash, "limit", strlen("limit"), newSViv(num), 0);
        // increment this
        SvREFCNT_inc(self);


SV *
skip (self, num)
        SV *self
        int num
     PREINIT:
        mongo_cursor *cursor;
        HV *this_hash;
     CODE:
        cursor = (mongo_cursor*)perl_mongo_get_ptr_from_instance(self);
        if (cursor->started_iterating) {
          croak("cannot set skip() after query");
          return;
        }

        this_hash = SvSTASH(SvRV(self));

        // store skip
        hv_store(this_hash, "skip", strlen("skip"), newSViv(num), 0);
        // increment this
        SvREFCNT_inc(self);



void
mongo_cursor_DESTROY (self)
      SV *self
  PREINIT:
      SV *link;
      HV *this_hash;
      mongo_cursor *cursor;
  CODE:
      this_hash = SvSTASH(SvRV(self));
      link = hv_fetch(this_hash, "link", strlen("link"), 0);
      SvREFCNT_dec(link);

      printf("in cursor destroy\n");
      cursor = (mongo_cursor*)perl_mongo_get_ptr_from_instance(self);
      if (cursor->buf.start)
        Safefree(cursor->buf.start);
      Safefree(cursor);
