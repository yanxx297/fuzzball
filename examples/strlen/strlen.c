#include <stdio.h>
#include <stdlib.h>

#define SIZE 64
char str[SIZE];

size_t mystrlen(char *str){
    size_t i;
    for(i = 0; str[i] != '\0'; i++) ;
    return i;
}

int main(int argc, char **argv){
    mystrlen(str);
    return 0;
}

