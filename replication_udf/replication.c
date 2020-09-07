/*
this is just a poc for connecting to maxscale through a UDF
build with something like
gcc -fPIC -shared -o replication.so cJSON.c replication.c `mariadb_config --include`/server `mariadb_config --include` -lcurl -lm -L/usr/lib/x86_64-linux-gnu/ -lmariadb
then copy the resulting "replication.so" to the mysql plugin dir
/usr/lib/mysql/plugin
*/

#ifdef _WIN32
/* Silence warning about deprecated functions , gethostbyname etc*/
#define _WINSOCK_DEPRECATED_NO_WARNINGS
#endif

/* STANDARD is defined, don't use any mysql functions */
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#ifdef __WIN__
typedef unsigned __int64 ulonglong;	/* Microsofts 64 bit types */
typedef __int64 longlong;
#else
typedef unsigned long long ulonglong;
typedef long long longlong;
#endif /*__WIN__*/
#include <mysql.h>
#include <ctype.h>
#include <curl/curl.h>
#include "cJSON.h"



#if !defined(HAVE_GETHOSTBYADDR_R) || !defined(HAVE_SOLARIS_STYLE_GETHOST)
static pthread_mutex_t LOCK_hostname;
#endif

#define INIT_VARIABLES() \
  char* release_name = getenv("RELEASE_NAME"); \
  char *s = release_name; \
  while (*s) { \
    *s = toupper((unsigned char) *s); \
    if (*s == '-') \
    { \
      *s = '_'; \
    } \
    s++; \
  } \
  char maxscale_address_env[256] = ""; \
  char maxscale_port_env[256] = ""; \
  sprintf(maxscale_address_env,"%s_%s", release_name, "MARIADB_MAXSCALE_SERVICE_HOST"); \
  sprintf(maxscale_port_env,"%s_%s", release_name, "MARIADB_MAXSCALE_SERVICE_PORT"); \
  const char* maxscale_address = getenv(maxscale_address_env); \
  const char* maxscale_port = getenv(maxscale_port_env); \
  const char* maxscale_api_username_file_name = "/mnt/secrets-maxscale-api/username"; \
  const char* maxscale_api_password_file_name = "/mnt/secrets-maxscale-api/password"; \
  const char* server_username_file_name = "/mnt/secrets-maxscale/username"; \
  const char* server_password_file_name = "/mnt/secrets-maxscale/password"; \
  FILE* maxscale_api_username_file = fopen(maxscale_api_username_file_name, "r"); \
  FILE* maxscale_api_password_file = fopen(maxscale_api_password_file_name, "r"); \
  FILE* server_username_file = fopen(server_username_file_name, "r"); \
  FILE* server_password_file = fopen(server_password_file_name, "r"); \
  char maxscale_api_username[256]; \
  char maxscale_api_password[256]; \
  char server_username[256]; \
  char server_password[256]; \
  fgets(maxscale_api_username, sizeof(maxscale_api_username), maxscale_api_username_file); \
  fclose(maxscale_api_username_file); \
  fgets(maxscale_api_password, sizeof(maxscale_api_password), maxscale_api_password_file); \
  fclose(maxscale_api_password_file); \
  fgets(server_username, sizeof(server_username), server_username_file); \
  fclose(server_username_file); \
  fgets(server_password, sizeof(server_password), server_password_file); \
  fclose(server_password_file);

#define ERROR_CLEANUP_MESSAGE(message) \
  *is_null = 0; \
  sprintf(result, "%s", message); \
  *length = (uint) strlen(result);

#define ERROR_CLEANUP() \
    ERROR_CLEANUP_MESSAGE("ERROR.")

#define CURL_CLEANUP() \
  curl_easy_cleanup(curl); \
  curl_global_cleanup();

#define PARSE_FILTERS() \
  cJSON *json = cJSON_Parse(curl_result.ptr); \
  cJSON *data = cJSON_GetObjectItemCaseSensitive(json, "data"); \
  cJSON *relationships = cJSON_GetObjectItemCaseSensitive(data, "relationships"); \
  cJSON *filters = cJSON_GetObjectItemCaseSensitive(relationships, "filters");

#define SET_CURL() \
    curl_easy_setopt(curl, CURLOPT_URL, url); \
    curl_easy_setopt(curl, CURLOPT_HTTPAUTH, CURLAUTH_BASIC); \
    curl_easy_setopt(curl, CURLOPT_USERNAME, maxscale_api_username); \
    curl_easy_setopt(curl, CURLOPT_PASSWORD, maxscale_api_password);

// definitions
my_bool set_htap_replication_init(UDF_INIT *initid, UDF_ARGS *args, char *message);
char* set_htap_replication(UDF_INIT *initid, UDF_ARGS *args, char *result, unsigned long *length, char *is_null, char *error);

my_bool show_htap_replication_init(UDF_INIT *initid, UDF_ARGS *args, char *message);
char* show_htap_replication(UDF_INIT *initid, UDF_ARGS *args, char *result, unsigned long *length, char *is_null, char *error);
void show_htap_replication_deinit(UDF_INIT* initid);

// helper functions
struct string {
  char *ptr;
  size_t len;
};

void init_string(struct string *s) {
  s->len = 0;
  s->ptr = malloc(s->len+1);
  if (s->ptr == NULL) {
    fprintf(stderr, "malloc() failed\n");
    exit(EXIT_FAILURE);
  }
  s->ptr[0] = '\0';
}

size_t writefunc(void *ptr, size_t size, size_t nmemb, struct string *s)
{
  size_t new_len = s->len + size*nmemb;
  s->ptr = realloc(s->ptr, new_len+1);
  if (s->ptr == NULL) {
    fprintf(stderr, "realloc() failed\n");
    exit(EXIT_FAILURE);
  }
  memcpy(s->ptr+s->len, ptr, size*nmemb);
  s->ptr[new_len] = '\0';
  s->len = new_len;

  return size*nmemb;
}

// returns 0 on success, something else on failure
int restart_slave_replication(char * server_username, char * server_password)
{
    // restart replication so that the new settings are loaded
    MYSQL *con = mysql_init(NULL);
    if (con == NULL) {
      return 1;
    }

    if (mysql_real_connect(con, "127.0.0.1", server_username, server_password, NULL, 3306, NULL, 0) == NULL) {
      mysql_close(con);
      return 2;
    }

    if (mysql_query(con, "STOP SLAVE;")) {
      mysql_close(con);
      return 3;
    }

    if (mysql_query(con, "START SLAVE;")) {
      mysql_close(con);
      return 4;
    }

    mysql_close(con);
    return 0;
}

int get_filters_list(CURL *curl, const char * maxscale_address, const char * maxscale_port, char * maxscale_api_username, char * maxscale_api_password, struct string * curl_result) {
  CURLcode res;

  char url[512] = "";
  sprintf(url,"http://%s:%s/v1/filters", maxscale_address, maxscale_port);
  SET_CURL();
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writefunc);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, curl_result);

  res = curl_easy_perform(curl);

  if(res == CURLE_OK)
  {
    long response_code;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
    // response codes in the 2XX range are good
    if (response_code / 100 != 2 ) {
      return 1;
    } else {
      return 0;
    }
  } else {
    return 1;
  }
}

int check_if_exists(const char * json_string, const char * replication_name) {
  cJSON *json = cJSON_Parse(json_string);
  cJSON *data = cJSON_GetObjectItemCaseSensitive(json, "data");

  int match = 0;
  if (cJSON_IsArray(data)) {
    const cJSON *filter = NULL;
    cJSON_ArrayForEach(filter, data)
    {
      cJSON *id = cJSON_GetObjectItemCaseSensitive(filter, "id");
      if (cJSON_IsString(id) && (id->valuestring != NULL) && (strcmp(replication_name, id->valuestring) == 0))
      {
        // already exists
        match = 1;
      }
    }
  }
  cJSON_Delete(json);
  return match;
}

char * build_filter(const char * replication_name, const char * replication_table, const char * replication_source, const char * replication_target)
{
    cJSON *json = cJSON_CreateObject();
    cJSON *data = cJSON_CreateObject();
    cJSON_AddItemToObject(json, "data", data);
    cJSON_AddItemToObject(data, "id", cJSON_CreateString(replication_name));
    cJSON_AddItemToObject(data, "type", cJSON_CreateString("filters"));
    cJSON *attributes = cJSON_CreateObject();
    cJSON_AddItemToObject(data, "attributes", attributes);
    cJSON_AddItemToObject(attributes, "module", cJSON_CreateString("binlogfilter"));
    cJSON *parameters = cJSON_CreateObject();
    cJSON_AddItemToObject(attributes, "parameters", parameters);
    if (strlen(replication_table) < 1) {
      // this filter should allow nothing
      cJSON_AddItemToObject(parameters, "exclude", cJSON_CreateString(".*"));
      // "N/A" is a clue to the user that this is turned off
      cJSON_AddItemToObject(parameters, "match", cJSON_CreateString("N/A"));
      cJSON_AddItemToObject(parameters, "rewrite_src", cJSON_CreateString("N/A"));
      cJSON_AddItemToObject(parameters, "rewrite_dest", cJSON_CreateString("N/A"));
    } else {
      cJSON_AddItemToObject(parameters, "exclude", cJSON_CreateString("(?!)")); // guaranteed to match nothing

      char match_regex[1024] = "";
      sprintf(match_regex, "(?#%s)", replication_table);

      char replication_table_var[1024] = "";
      sprintf(replication_table_var, "%s", replication_table);

      // split the supplied match filter by "|"
      char *token = strtok(replication_table_var, "|");
      int token_count = 0;
      while( token != NULL ) {
        if (token_count > 0) {
          sprintf(match_regex + strlen(match_regex), "|");
        }
        ++token_count;
        sprintf(match_regex + strlen(match_regex), "\\b%s\\b", token );
        token = strtok(NULL, "|");
      }
   
      cJSON_AddItemToObject(parameters, "match", cJSON_CreateString(match_regex));

      char rewrite_regex[512] = "";
      sprintf(rewrite_regex, "(?#%s)(^%s$)|((?<=`)%s(?=`))|((?<=[ (,])%s(?=[.]))", replication_source, replication_source, replication_source, replication_source);
      cJSON_AddItemToObject(parameters, "rewrite_src", cJSON_CreateString(rewrite_regex));

      cJSON_AddItemToObject(parameters, "rewrite_dest", cJSON_CreateString(replication_target));
    }
    char * data_string = cJSON_PrintUnformatted(json);
    cJSON_Delete(json);
    return data_string;
}

int delete_replication(CURL *curl, const char *replication)
{
  INIT_VARIABLES();

  CURLcode res;

  if(curl)
  {
    struct string curl_result;
    init_string(&curl_result);

    // get filters list
    char url[512] = "";
    sprintf(url,"http://%s:%s/v1/services/Replication-Service", maxscale_address, maxscale_port);
    SET_CURL();
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writefunc);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &curl_result);

    res = curl_easy_perform(curl);

    if(res == CURLE_OK) {
      long response_code;
      curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
      if (response_code / 100 != 2) {
        free(curl_result.ptr);
        return 1;
      }
    } else {
      free(curl_result.ptr);
      return 2;
    }

    // parse the current filters
    PARSE_FILTERS();
    free(curl_result.ptr);
    if (cJSON_IsObject(filters)) {
      data = cJSON_GetObjectItemCaseSensitive(filters, "data");
      // remove filter from service json
      const cJSON *filter = NULL;
      int i = 0;
      int to_delete = -1;
      cJSON_ArrayForEach(filter, data)
      {
        cJSON *id = cJSON_GetObjectItemCaseSensitive(filter, "id");
        if (cJSON_IsString(id) && (id->valuestring != NULL) && (strcmp(replication, id->valuestring) == 0))
        {
          to_delete = i;
        }
        ++i;
      }

      if (to_delete >= 0) {
        cJSON_DeleteItemFromArray(data, to_delete);
        cJSON_DeleteItemFromObject(filters, "links");
        char *filters_string = cJSON_PrintUnformatted(filters);
        
        curl_easy_reset(curl);

        // patch service to remove the filter
        sprintf(url,"http://%s:%s/v1/services/Replication-Service/relationships/filters", maxscale_address, maxscale_port);
        SET_CURL();
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "PATCH");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, filters_string);
        struct curl_slist *headers_list = NULL;
        headers_list = curl_slist_append(headers_list, "Content-Type: application/json");
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers_list);

        res = curl_easy_perform(curl);
        free(filters_string);
        curl_slist_free_all(headers_list);
        if(res == CURLE_OK) {
          long response_code;
          curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
          if (response_code / 100 != 2) {
            cJSON_Delete(json);
            return 3;
          }
        } else {
          cJSON_Delete(json);
          return 4;
        }
      }
    }
    cJSON_Delete(json);

    // delete filter
    curl_easy_reset(curl);
    sprintf(url,"http://%s:%s/v1/filters/%s", maxscale_address, maxscale_port, replication);
    SET_CURL();
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "DELETE");
    res = curl_easy_perform(curl);

    if(res == CURLE_OK) {
      long response_code;
      curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
      if (response_code / 100 != 2) {
        return 5;
      }
    } else {
      return 6;
    }

    return 0;
  }
  else
  {
    return 7;
  }
}

// implementations
my_bool set_htap_replication_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
  if (args->arg_count != 3 || args->arg_type[0] != STRING_RESULT || args->arg_type[1] != STRING_RESULT || args->arg_type[2] != STRING_RESULT)
  {
    strcpy(message,"Wrong number of arguments, should be 3 string arguments");
    return 1;
  }

  return 0;
}

char* set_htap_replication(UDF_INIT *initid, UDF_ARGS *args __attribute__((unused)),
                char *result, unsigned long *length,
                char *is_null, char *error __attribute__((unused)))
{
  const char *replication_table = args->args[0];
  const char *replication_source = args->args[1];
  const char *replication_target = args->args[2];
  const char replication_name[256] = "replication_filter";

  INIT_VARIABLES();

  CURL *curl;
  CURLcode res;

  // create filter
  curl_global_init(CURL_GLOBAL_DEFAULT);
  curl = curl_easy_init();
  if(curl)
  {
    // get current filters list
    struct string curl_result;
    init_string(&curl_result);

    if (get_filters_list(curl, maxscale_address, maxscale_port, maxscale_api_username, maxscale_api_password, &curl_result))
    {
      ERROR_CLEANUP();
      CURL_CLEANUP();
      free(curl_result.ptr);
      return result;
    }

    // check if filter already exists
    if (check_if_exists(curl_result.ptr, replication_name))
    {
      free(curl_result.ptr);
      init_string(&curl_result);
      curl_easy_reset(curl);
      if (delete_replication(curl, replication_name)) {
        ERROR_CLEANUP();
        CURL_CLEANUP();
        free(curl_result.ptr);
        return result;
      }
    }
    
    free(curl_result.ptr);
    curl_easy_reset(curl);
    
    // build the filter json
    char * data_string = build_filter(replication_name, replication_table, replication_source, replication_target);
    
    // add the new filter
    char url[512] = "";
    sprintf(url,"http://%s:%s/v1/filters", maxscale_address, maxscale_port);
    SET_CURL();
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, data_string);
    struct curl_slist *headers_list = NULL;
    headers_list = curl_slist_append(headers_list, "Content-Type: application/json");
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers_list);

    res = curl_easy_perform(curl);

    free(data_string);
    curl_slist_free_all(headers_list);

    if(res == CURLE_OK)
    {
      long response_code;
      curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
      if (response_code / 100 != 2) {
        ERROR_CLEANUP();
        CURL_CLEANUP();
        return result;
      }
    } else {
      ERROR_CLEANUP();
      CURL_CLEANUP();
      return result;
    }

    curl_easy_reset(curl);
    init_string(&curl_result);

    // get the current filters
    sprintf(url,"http://%s:%s/v1/services/Replication-Service", maxscale_address, maxscale_port);
    SET_CURL();
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writefunc);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &curl_result);

    res = curl_easy_perform(curl);

    if(res == CURLE_OK)
    {
      long response_code;
      curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
      if (response_code / 100 != 2) {
        ERROR_CLEANUP();
        CURL_CLEANUP();
        free(curl_result.ptr);
        return result;
      }
    } else {
      ERROR_CLEANUP();
      CURL_CLEANUP();
      free(curl_result.ptr);
      return result;
    }

    // parse the current filters list and fill missing fields
    PARSE_FILTERS();
    free(curl_result.ptr);
    if (cJSON_IsObject(filters)) {
      cJSON_DeleteItemFromObject(filters, "links");
      data = cJSON_GetObjectItemCaseSensitive(filters, "data");
      if (!cJSON_IsArray(data)) {
        cJSON_AddItemToObject(filters, "data", cJSON_CreateArray());
        data = cJSON_GetObjectItemCaseSensitive(filters, "data");
      }
    } else {
      filters = cJSON_CreateObject();
      cJSON_AddItemToObject(relationships, "filters", filters);
      cJSON_AddItemToObject(filters, "data", cJSON_CreateArray());
      data = cJSON_GetObjectItemCaseSensitive(filters, "data");
    }

    // create the new filter json
    cJSON *new_filter = cJSON_CreateObject();
    cJSON_AddItemToObject(new_filter, "type", cJSON_CreateString("filters"));
    cJSON_AddItemToObject(new_filter, "id", cJSON_CreateString(replication_name));

    // add new filter
    cJSON_AddItemToArray(data, new_filter);
    char *filters_string = cJSON_PrintUnformatted(filters);

    cJSON_Delete(json);

    // reset curl
    curl_easy_reset(curl);

    // add the new filter to the service
    sprintf(url,"http://%s:%s/v1/services/Replication-Service/relationships/filters", maxscale_address, maxscale_port);
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "PATCH");
    SET_CURL();
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, filters_string);
    headers_list = NULL;
    headers_list = curl_slist_append(headers_list, "Content-Type: application/json");
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers_list);

    res = curl_easy_perform(curl);
    free(filters_string);
    curl_slist_free_all(headers_list);
    if(res == CURLE_OK) {
      long response_code;
      curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
      if (response_code / 100 != 2) {
        ERROR_CLEANUP();
        CURL_CLEANUP();
        return result;
      }
    } else {
      ERROR_CLEANUP();
      CURL_CLEANUP();
      return result;
    }

    curl_easy_cleanup(curl);
    curl_global_cleanup();

    // restart replication so that the new settings are loaded
    int restart_error = restart_slave_replication(server_username, server_password);
    if (restart_error) {
      char str[10];
      sprintf(str, "%d", restart_error);
      ERROR_CLEANUP_MESSAGE(str);
      return result;
    }

    *is_null = 0;
    sprintf(result, "%s", "Success.");
    *length = (uint) strlen(result);
    return result;
  }
  else
  {
    curl_global_cleanup();
    ERROR_CLEANUP();
    return result;
  }
}

void
show_htap_replication_deinit( UDF_INIT* initid )
{
  free(initid->ptr);
}

my_bool show_htap_replication_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
  if (args->arg_count != 0)
  {
    strcpy(message,"Wrong number of arguments, should be 0 arguments");
    return 1;
  }
  
  char *str_to_ret = malloc (sizeof (char) * 10240);
  initid->ptr = str_to_ret;
  initid->max_length = 10240;

  return 0;
}

char* show_htap_replication(UDF_INIT *initid, UDF_ARGS *args __attribute__((unused)),
                char *result, unsigned long *length,
                char *is_null, char *error __attribute__((unused)))
{
  INIT_VARIABLES();

  CURL *curl;
  CURLcode res;

  curl_global_init(CURL_GLOBAL_DEFAULT);
  curl = curl_easy_init();
  if(curl)
  {
    // get filters list
    struct string curl_result;
    init_string(&curl_result);

    if (get_filters_list(curl, maxscale_address, maxscale_port, maxscale_api_username, maxscale_api_password, &curl_result))
    {
      ERROR_CLEANUP();
      CURL_CLEANUP();
      free(curl_result.ptr);
      return result;
    }

    curl_easy_cleanup(curl);

    cJSON *json = cJSON_Parse(curl_result.ptr);
    free(curl_result.ptr);
    cJSON *data = cJSON_GetObjectItemCaseSensitive(json, "data");

    const cJSON *filter = NULL;
    sprintf(initid->ptr, "\n");
    cJSON_ArrayForEach(filter, data)
    {
      cJSON *id = cJSON_GetObjectItemCaseSensitive(filter, "id");
      cJSON *attributes = cJSON_GetObjectItemCaseSensitive(filter, "attributes");
      cJSON *module = cJSON_GetObjectItemCaseSensitive(attributes, "module");
      if (cJSON_IsString(module) && (module->valuestring != NULL) && (strcmp("binlogfilter", module->valuestring) == 0))
      {
        cJSON *parameters = cJSON_GetObjectItemCaseSensitive(attributes, "parameters");

        cJSON *match = cJSON_GetObjectItemCaseSensitive(parameters, "match");
        // find the original source db hiddent in the regex comment
        char parsed_table[512] = "";
        if (strlen(match->valuestring) > 5) {
          int new_line_pos = (int)(strchr(match->valuestring, ')') - match->valuestring);
          sprintf(parsed_table, "%.*s", new_line_pos - 3, match->valuestring + 3);
        } else {
          sprintf(parsed_table, "%s", match->valuestring);
        }

        cJSON *rewrite_src = cJSON_GetObjectItemCaseSensitive(parameters, "rewrite_src");

        cJSON *rewrite_dest = cJSON_GetObjectItemCaseSensitive(parameters, "rewrite_dest");
        // find the original source db hiddent in the regex comment
        char parsed_source_db[512] = "";
        if (strlen(rewrite_src->valuestring) > 5) {
          int new_line_pos = (int)(strchr(rewrite_src->valuestring, ')') - rewrite_src->valuestring);
          sprintf(parsed_source_db, "%.*s", new_line_pos - 3, rewrite_src->valuestring + 3);
        } else {
          sprintf(parsed_source_db, "%s", rewrite_src->valuestring);
        }

        sprintf(initid->ptr + strlen(initid->ptr), "\t=== %s ===\n\ttable: %s\n\tsource database: %s\n\ttarget database: %s\n\n", id->valuestring, parsed_table, parsed_source_db, rewrite_dest->valuestring);
      }
    }

    cJSON_Delete(json);
    curl_global_cleanup();

    *is_null = 0;
    *length = (uint) strlen(initid->ptr);
    return initid->ptr;
  }
  else
  {
    curl_global_cleanup();
    ERROR_CLEANUP();
    return result;
  }
}

