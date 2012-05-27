/*
********************************************************************************
*
*  File: psad.h
*
*  Author: Michael Rash (mbr@cipherdyne.org)
*
*  Purpose: psad.h include appropriate system header files, and defines file
*           paths, function prototypes, and constants that are needed by
*           the C versions of psad.
*
*  Credits:  (see the CREDITS file)
*
*  Copyright (C) 1999-2006 Michael Rash (mbr@cipherdyne.org)
*
*  License (GNU Public License):
*
*     This program is distributed in the hope that it will be useful,
*     but WITHOUT ANY WARRANTY; without even the implied warranty of
*     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*     GNU General Public License for more details.
*
*     You should have received a copy of the GNU General Public License
*     along with this program; if not, write to the Free Software
*     Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307
*     USA
*
********************************************************************************
*/

#ifndef __PSAD_H__
#define __PSAD_H__

/* INCLUDES *******************************************************************/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>    /* read(), write(), and close() */
#include <fcntl.h>     /* open() */
#include <sys/stat.h>  /* umask */
#include <sys/wait.h>
#include <sys/types.h>
#include <signal.h>
#include <syslog.h>
#include <ctype.h>

/* DEFINES ********************************************************************/
#define PSAD_VERSION      "2.1.6-pre1"
#define MAX_LINE_BUF 1024
#define MAX_PID_SIZE 6
#define MAX_PATH_LEN 100
#define MAX_MSG_LEN 120
#define MAX_GEN_LEN 80
#define MAX_EMAIL_LEN 300
#define MAX_ARG_LEN 30
#define MAX_NUM_LEN 6

/* PROTOTYPES *****************************************************************/
void slogr(const char *, const char *);
void check_unique_pid(const char *, const char *);
void write_pid(const char *, pid_t);
void daemonize_process(const char *);
void send_alert_email(const char *, const char *, const char *);
int has_sub_var(char *var_name, char *value, char *sub_var,
    char *pre_str, char *post_str);
void expand_sub_var_value(char *value, const char *sub_var,
    const char *pre_str, const char *post_str);
int find_char_var(const char *, char *, char *);
int check_import_config(time_t *config_mtime, char *config_file);
void *safe_malloc(const unsigned int len);
void list_to_array(char *ptList, const char sep, char **array,
    unsigned char max_arg);

/* From OpenBSD */
size_t strlcpy(char *, const char *, size_t);
size_t strlcat(char *, const char *, size_t);

#endif  /* __PSAD_H__ */
