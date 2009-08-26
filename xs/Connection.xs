#include "perl_mongo.h"
#include "mongo_link.h"

extern int request_id;

MODULE = MongoDB::Connection  PACKAGE = MongoDB::Connection

PROTOTYPES: DISABLE



void
connect (self)
                SV *self
	PREINIT:
                int paired;
                SV *host_sv = 0, *port_sv, 
                    *left_host_sv, *right_host_sv,
                    *left_port_sv, *right_port_sv;
		mongo_link *link;
	INIT:
                left_host_sv = perl_mongo_call_reader (ST(0), "left_host");
                right_host_sv = perl_mongo_call_reader (ST(0), "right_host");

                paired = SvOK(left_host_sv) && SvOK(right_host_sv);
                if (paired) {
                  left_port_sv = perl_mongo_call_reader (ST(0), "left_port");
                  right_port_sv = perl_mongo_call_reader (ST(0), "right_port");
                }
                else {
                  host_sv = perl_mongo_call_reader (ST (0), "host");
                  port_sv = perl_mongo_call_reader (ST (0), "port");
                }
	CODE:
	        Newx(link, 1, mongo_link);
		perl_mongo_attach_ptr_to_instance(self, link);

                link->paired = paired;
                link->ts = time(0);
                if (paired) {
                  link->server.pair.left_host = SvPV_nolen(left_host_sv);
                  link->server.pair.left_port = SvIV(left_port_sv);

                  link->server.pair.right_host = SvPV_nolen(right_host_sv);
                  link->server.pair.right_port = SvIV(right_port_sv);
                }
                else {
                  link->server.single.host = SvPV_nolen(host_sv);
                  link->server.single.port = SvIV(port_sv);
                }

                // TODO: pairing
                // this will be be server1, server2 
		if (!mongo_link_connect(link)) {
                  croak ("couldn't connect to server");
                  return;
		}
	CLEANUP:
                if (paired) {
                  SvREFCNT_dec(left_host_sv);
                  SvREFCNT_dec(left_port_sv);
                  SvREFCNT_dec(right_host_sv);
                  SvREFCNT_dec(right_port_sv);
                }
                else {
                  SvREFCNT_dec (host_sv);
                  SvREFCNT_dec (port_sv);
                }

SV *
_query (self, ns, query=0, limit=0, skip=0, sort=0)
        SV *self
        const char *ns
        SV *query
        int limit
        int skip
        SV *sort
    PREINIT:
        mongo_cursor *cursor;
        SV **socket;
        HV *this_hash, *stash, *rcursor, *full_query;
    CODE:
        // create a new MongoDB::Cursor
        stash = gv_stashpv("MongoDB::Cursor", 0);
        rcursor = newHV();
        RETVAL = sv_bless(newRV_noinc((SV *)rcursor), stash);

        // associate this connection with the cursor
        hv_store(stash, "link", strlen("link"), self, 0);
        SvREFCNT_inc(self);

        // attach a mongo_cursor* to the MongoDB::Cursor
        Newx(cursor, 1, mongo_cursor);
        perl_mongo_attach_ptr_to_instance(RETVAL, cursor);

        // START cursor setup

        // set the namespace
        cursor->ns = ns;

        // create the query
        full_query = newHV();
        cursor->query = newRV_noinc((SV*)full_query);

        // add the query to the... query
        if (!query || !SvOK(query)) {
          query = newRV_noinc((SV*)newHV());
        }
        hv_store(full_query, "query", strlen("query"), SvREFCNT_inc(query), 0);

        // add sort to the query
        if (sort && SvOK(sort)) {
          hv_store(full_query, "orderby", strlen("orderby"), SvREFCNT_inc(sort), 0);
        }
        hv_store(stash, "query", strlen("query"), newRV_noinc(full_query), 0);

        // add limit/skip
        cursor->limit = limit;
        cursor->skip = skip;

	// zero results fields
	cursor->num = 0;
	cursor->at = 0;

        // zero other fields
        cursor->fields = 0;
        cursor->opts = 0;
        cursor->started_iterating = 0;

        // clear the buf
        cursor->buf.start = 0;
        cursor->buf.pos = 0;
        cursor->buf.end = 0;

        // STOP cursor setup

    OUTPUT:
        RETVAL


SV *
_find_one (self, ns, query)
	SV *self
        const char *ns
        SV *query
    PREINIT:
        SV *cursor;
    CODE:
        // create a cursor with limit = -1
        cursor = perl_mongo_call_method(self, "_query", 3, ST(1), ST(2), newSViv(-1));
        RETVAL = perl_mongo_call_method(cursor, "next", 0);
    OUTPUT:
        RETVAL
    CLEANUP:
        SvREFCNT_dec (cursor);


void
_insert (self, ns, object)
        SV *self
        const char *ns
        SV *object
    PREINIT:
        SV *oid_class;
        mongo_link *link;
        mongo_msg_header header;
        buffer buf;
    INIT:
        oid_class = perl_mongo_call_reader (ST (0), "_oid_class");
    CODE:
        link = (mongo_link*)perl_mongo_get_ptr_from_instance(self);

        CREATE_BUF(INITIAL_BUF_SIZE);
        CREATE_HEADER(buf, ns, OP_INSERT);
        perl_mongo_sv_to_bson(&buf, object, SvPV_nolen (oid_class));
        serialize_size(buf.start, &buf);

        // sends
        mongo_link_say(link, &buf);
        Safefree(buf.start);
      CLEANUP:
        SvREFCNT_dec (oid_class);

void
_remove (self, ns, query, just_one)
        SV *self
        const char *ns
        SV *query
        bool just_one
    PREINIT:
        SV *oid_class;
        mongo_link *link;
        mongo_msg_header header;
        buffer buf;
    INIT:
        oid_class = perl_mongo_call_reader (ST (0), "_oid_class");
    CODE:
        link = (mongo_link*)perl_mongo_get_ptr_from_instance(self);

        CREATE_BUF(INITIAL_BUF_SIZE);
        CREATE_HEADER(buf, ns, OP_DELETE);
        serialize_int(&buf, (int)(just_one == 1));
        perl_mongo_sv_to_bson(&buf, query, SvPV_nolen (oid_class));
        serialize_size(buf.start, &buf);

        // sends
        mongo_link_say(link, &buf);
        Safefree(buf.start);
    CLEANUP:
        SvREFCNT_dec (oid_class);

void
_update (self, ns, query, object, upsert)
        SV *self
        const char *ns
        SV *query
        SV *object
        bool upsert
    PREINIT:
        SV *oid_class;
        mongo_link *link;
        mongo_msg_header header;
        buffer buf;
    INIT:
        oid_class = perl_mongo_call_reader (ST (0), "_oid_class");
    CODE:
        link = (mongo_link*)perl_mongo_get_ptr_from_instance(self);

        CREATE_BUF(INITIAL_BUF_SIZE);
        CREATE_HEADER(buf, ns, OP_UPDATE);
        serialize_int(&buf, upsert);
        perl_mongo_sv_to_bson(&buf, query, SvPV_nolen (oid_class));
        perl_mongo_sv_to_bson(&buf, object, SvPV_nolen (oid_class));
        serialize_size(buf.start, &buf);

        // sends
        mongo_link_say(link, &buf);
        Safefree(buf.start);
    CLEANUP:
        SvREFCNT_dec (oid_class);

void
_ensure_index (self, ns, keys, unique=0)
	SV *self
        const char *ns
        SV *keys
        int unique
    PREINIT:
        HV *key_hash;
        SV *ret;
    CODE:
        key_hash = SvRV(keys);
        hv_store(key_hash, "unique", strlen("unique"), unique ? &PL_sv_yes : &PL_sv_no, 0);
        ret = perl_mongo_call_method(self, "_insert", 2, ST(1), ST(2));
    CLEANUP:
        SvREFCNT_dec (ret);


NO_OUTPUT bool
_authenticate (self, dbname, username, password, is_digest=0)
	SV *self
        const char *dbname
        const char *username
        const char *password
        bool is_digest
    PREINIT:
        //std::string error_message;
        //std::string digest_password;
    INIT:
        /*if (is_digest) {
            digest_password = password;
        } else {
            digest_password = THIS->createPasswordDigest(username, password);
        }*/
    CODE:
        //RETVAL = THIS->auth(dbname, username, password, error_message, true);


void
connection_DESTROY (self)
          SV *self
     PREINIT:
         mongo_link *link;
     CODE:
         link = (mongo_link*)perl_mongo_get_ptr_from_instance(self);
         Safefree(link);
         printf("in destroy\n");
