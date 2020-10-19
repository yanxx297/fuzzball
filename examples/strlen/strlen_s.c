#include <stdio.h>
#include <stdlib.h>

size_t strlen_s(char *str){
    char *s;
    for(s = str; *s; ++s) ;
    return (s-str);
}

int main(int argc, char **argv){
    return 0;
}

