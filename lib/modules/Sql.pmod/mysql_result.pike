/*
 * $Id$
 *
 * Glue for the Mysql-module
 */

#pike __REAL_VERSION__

#if constant(Mysql.mysql_result)
inherit Mysql.mysql_result;
#else /* !constant(Mysql.mysql_result) */
constant this_program_does_not_exist=1;
#endif /* constant(Mysql.mysql_result) */

