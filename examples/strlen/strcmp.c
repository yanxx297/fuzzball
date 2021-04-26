#include <stdio.h>
#include <stdlib.h>

#define SIZE 64
char str1[SIZE];
char str2[SIZE];

int mystrcmp(char *str1, char *str2){
    for(int i = 0;; i++){
	if(str1[i] != str2[i]) 
	    return str1[i] < str2[2]?-1:1;
	if(str1[i] == '\0')
	    return 0;
    }
}

void main(int argc, char **argv){
    mystrcmp(str1, str2);
    return;
}

