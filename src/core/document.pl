:- module(document,
          [
              % validation.pl
              refute_validation_objects/2,

              % json.pl
              idgen_random/2,
              idgen_hash/3,
              idgen_lexical/3,

              json_elaborate/3,
              json_triple/3,
              json_schema_triple/3,
              json_schema_elaborate/3,
              context_triple/2,
              database_prefixes/2,
              insert_context_document/2,
              run_insert_document/4,
              create_graph_from_json/5,
              write_json_stream_to_builder/3,
              write_json_stream_to_schema/2,
              write_json_stream_to_instance/2,
              write_json_string_to_schema/2,
              write_json_string_to_instance/2,
              replace_json_schema/2,

              get_document/3,
              get_document/5,
              get_document_uri/3,
              get_schema_document/3,
              get_schema_document_uri/2,
              get_document_uri_by_type/3,
              get_schema_document_uri_by_type/3,
              delete_document/2,
              insert_document/3,
              replace_document/2,
              replace_document/3,
              nuke_documents/1,
              insert_schema_document/2,
              delete_schema_document/2,
              replace_schema_document/2,
              replace_schema_document/3,
              nuke_schema_documents/1,

              % instance.pl
              is_instance/3,

              % schema.pl
              class_subsumed/3,
              class_frame/3,
              is_schemaless/1,

              % query.pl
              match_query_document_uri/4
          ]).

:- use_module('document/validation').
:- use_module('document/json').
:- use_module('document/schema').
:- use_module('document/instance').
:- use_module('document/query').
